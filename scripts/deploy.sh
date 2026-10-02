#!/usr/bin/env bash
# Deploys Feedback Board in phases.
#   ALERT_EMAIL=you@example.com GITHUB_REPO=owner/feedback-board scripts/deploy.sh core
#   scripts/deploy.sh ec2      # Jenkins + EC2 Auto Scaling group + RDS (needs core)
#   scripts/deploy.sh eks      # EKS cluster running the same image (needs core)
set -euo pipefail
cd "$(dirname "$0")/.."

PHASE=${1:?usage: deploy.sh core|ec2|eks}
ENV=${ENV_NAME:-prod}
export AWS_REGION=${AWS_REGION:-ap-south-1} AWS_DEFAULT_REGION=${AWS_REGION:-ap-south-1}

tf() { terraform -chdir=terraform "$@"; }
out() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
cfn() { # stack template params...
  local stack=$1 tpl=$2; shift 2
  echo "==> $stack"
  aws cloudformation deploy --stack-name "$stack" --template-file "$tpl" --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset --tags Project=feedback-board Env="$ENV" --parameter-overrides EnvName="$ENV" "$@"
}

foundation() {
  KMS=$(tf output -raw kms_key_arn); ECR=$(tf output -raw ecr_repository_url)
  TOPIC=$(tf output -raw alerts_topic_arn); BUCKET=$(tf output -raw artifact_bucket)
  VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true \
    --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
}

core() {
  : "${ALERT_EMAIL:?set ALERT_EMAIL}" "${GITHUB_REPO:?set GITHUB_REPO}"
  echo "==> Terraform foundation (KMS, CloudTrail, ECR, SNS, artifact bucket)"
  tf init -input=false
  tf apply -input=false -auto-approve -var alert_email="$ALERT_EMAIL"
  foundation

  aws cloudformation package --template-file infra/1-serverless.yaml --s3-bucket "$BUCKET" --s3-prefix lambda \
    --kms-key-id "$KMS" --output-template-file packaged-serverless.yaml >/dev/null
  cfn "feedback-serverless-$ENV" packaged-serverless.yaml KmsKeyArn="$KMS"
  aws s3 cp web/index.html "s3://$(out "feedback-serverless-$ENV" SiteBucketName)/index.html" --cache-control max-age=60

  echo "==> Bootstrap image"
  aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%%/*}"
  docker build --build-arg APP_VERSION=bootstrap -t "$ECR:bootstrap" app
  docker push "$ECR:bootstrap" || true   # tags are immutable; already pushed on re-runs

  cfn "feedback-ecs-$ENV" infra/2-ecs.yaml VpcId="$VPC" SubnetIds="$SUBNETS" ImageUri="$ECR:bootstrap" \
    KmsKeyArn="$KMS" AlertsTopicArn="$TOPIC"
  cfn "feedback-monitoring-$ENV" infra/3-monitoring.yaml AlertsTopicArn="$TOPIC"
  cfn "feedback-pipeline-$ENV" infra/4-pipeline.yaml GitHubRepo="$GITHUB_REPO" KmsKeyArn="$KMS" \
    AlertsTopicArn="$TOPIC" EcrRepositoryUri="$ECR" ArtifactBucketName="$BUCKET"

  cat <<EOF

Done. One-time manual steps:
  1. Confirm the SNS subscription email sent to $ALERT_EMAIL
  2. Approve the GitHub connection: Console > Developer Tools > Settings > Connections > feedback-github-$ENV
     then: aws codepipeline start-pipeline-execution --name feedback-board-$ENV
App:       $(out "feedback-serverless-$ENV" SiteUrl)
Dashboard: $(out "feedback-ecs-$ENV" DashboardUrl)
Pipeline:  $(out "feedback-pipeline-$ENV" PipelineUrl)
EOF
}

"$PHASE"
