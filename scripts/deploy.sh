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
  # Throwaway docker config: Windows credential stores reject ECR's long tokens.
  # A non-empty "auths" stops docker auto-selecting the OS store, so it uses this file instead.
  DOCKER_CONFIG=$(mktemp -d); export DOCKER_CONFIG; trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  echo '{"auths":{"placeholder.invalid":{}}}' > "$DOCKER_CONFIG/config.json"
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

ec2() {
  foundation
  local ip; ip=$(curl -s https://checkip.amazonaws.com)
  cfn "feedback-ec2-$ENV" infra/5-ec2.yaml VpcId="$VPC" SubnetIds="$SUBNETS" KmsKeyArn="$KMS" \
    AlertsTopicArn="$TOPIC" ArtifactBucketName="$BUCKET" AdminCidr="$ip/32"
  local jenkins; jenkins=$(out "feedback-ec2-$ENV" JenkinsInstanceId)
  cat <<EOF

Done. Jenkins: $(out "feedback-ec2-$ENV" JenkinsUrl)  (allowed from $ip only)
Configure Jenkins as code once it has installed (~3 min):
  aws ssm send-command --instance-ids $jenkins --document-name AWS-RunShellScript \\
    --parameters "{\"commands\":[\"echo $(base64 -w0 jenkins/configure.sh) | base64 -d | bash\"]}"
EC2 app: $(out "feedback-ec2-$ENV" Ec2AppUrl)
EOF
}

eks() {
  foundation
  local account; account=$(aws sts get-caller-identity --query Account --output text)
  sed -e "s|\${ACCOUNT_ID}|$account|g" -e "s|\${KMS_KEY_ARN}|$KMS|g" k8s/cluster.yaml > k8s/.cluster.rendered.yaml
  eksctl create cluster -f k8s/.cluster.rendered.yaml
  local tag; tag=$(aws ecr describe-images --repository-name feedback-board/dashboard \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' --output text)
  sed "s|\${IMAGE}|$ECR:$tag|" k8s/app.yaml | kubectl apply -f -
  kubectl rollout status deployment/feedback-dashboard --timeout=5m
  echo "EKS app: http://$(kubectl get svc feedback-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
}

"$PHASE"
