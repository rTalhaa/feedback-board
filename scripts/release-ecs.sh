#!/usr/bin/env bash
# Manual ECS blue/green release - the same steps the pipeline runs (build, push, new task definition revision,
# CodeDeploy deployment), for use when CodeBuild is unavailable.
#   scripts/release-ecs.sh <version> [app-dir]     e.g.  scripts/release-ecs.sh v2
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: release-ecs.sh <version> [app-dir]}
APP_DIR=${2:-app}
ENV=${ENV_NAME:-prod}
export AWS_REGION=${AWS_REGION:-ap-south-1} AWS_DEFAULT_REGION=${AWS_REGION:-ap-south-1}
ECR=$(aws ecr describe-repositories --repository-names feedback-board/dashboard --query 'repositories[0].repositoryUri' --output text)
FAMILY=feedback-dashboard-$ENV

# A non-empty "auths" stops docker auto-selecting the OS store (Windows rejects ECR's long tokens).
DOCKER_CONFIG=$(mktemp -d); export DOCKER_CONFIG; trap 'rm -rf "$DOCKER_CONFIG"' EXIT
echo '{"auths":{"placeholder.invalid":{}}}' > "$DOCKER_CONFIG/config.json"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%%/*}" >/dev/null
docker build -q --build-arg APP_VERSION="$VERSION" -t "$ECR:$VERSION" "$APP_DIR"
docker push -q "$ECR:$VERSION"

# Next revision = current one with the new image and version.
TD=$(aws ecs describe-task-definition --task-definition "$FAMILY" --query taskDefinition | python -c "
import json, sys
td = json.load(sys.stdin)
keep = ('family', 'taskRoleArn', 'executionRoleArn', 'networkMode', 'containerDefinitions',
        'requiresCompatibilities', 'cpu', 'memory', 'runtimePlatform')
td = {k: td[k] for k in keep}
c = td['containerDefinitions'][0]
c['image'] = '$ECR:$VERSION'
c['environment'] = [e for e in c['environment'] if e['name'] != 'APP_VERSION'] + [{'name': 'APP_VERSION', 'value': '$VERSION'}]
print(json.dumps(td))")
ARN=$(aws ecs register-task-definition --cli-input-json "$TD" --query taskDefinition.taskDefinitionArn --output text)

APPSPEC=$(python -c "import json; print(json.dumps({'version': 0.0, 'Resources': [{'TargetService': {'Type': 'AWS::ECS::Service', 'Properties': {'TaskDefinition': '$ARN', 'LoadBalancerInfo': {'ContainerName': 'dashboard', 'ContainerPort': 8080}}}}]}))")
REV=$(python -c "import json,sys; print(json.dumps({'revisionType': 'AppSpecContent', 'appSpecContent': {'content': sys.argv[1]}}))" "$APPSPEC")
aws deploy create-deployment --application-name "feedback-dashboard-$ENV" --deployment-group-name "feedback-dashboard-$ENV-bg" \
  --description "Release $VERSION" --revision "$REV" --query deploymentId --output text
