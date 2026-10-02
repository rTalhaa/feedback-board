#!/usr/bin/env bash
# Deletes everything, newest phase first.
#   scripts/teardown.sh eks | ec2 | all
set -euo pipefail
cd "$(dirname "$0")/.."

PHASE=${1:?usage: teardown.sh eks|ec2|all}
ENV=${ENV_NAME:-prod}
export AWS_REGION=${AWS_REGION:-ap-south-1} AWS_DEFAULT_REGION=${AWS_REGION:-ap-south-1}

drop() {
  echo "==> deleting $1"
  aws cloudformation delete-stack --stack-name "$1"
  aws cloudformation wait stack-delete-complete --stack-name "$1"
}

eks() {
  kubectl delete -f k8s/app.yaml --ignore-not-found 2>/dev/null || true   # removes the load balancer first
  eksctl delete cluster --name feedback-prod --region "$AWS_REGION" --wait || true
}

ec2() { drop "feedback-ec2-$ENV"; }

all() {
  eks; ec2
  local site; site=$(aws cloudformation describe-stacks --stack-name "feedback-serverless-$ENV" \
    --query "Stacks[0].Outputs[?OutputKey=='SiteBucketName'].OutputValue" --output text 2>/dev/null || true)
  [ -n "$site" ] && aws s3 rm "s3://$site" --recursive
  for s in pipeline monitoring ecs serverless; do drop "feedback-$s-$ENV"; done
  terraform -chdir=terraform destroy -input=false -auto-approve -var alert_email=unused@example.com
}

"$PHASE"
echo "Remaining stacks:"
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE \
  --query 'StackSummaries[?starts_with(StackName,`feedback`) || starts_with(StackName,`eksctl`)].StackName' --output text
