#!/usr/bin/env bash
set -euo pipefail

# このスクリプトは GitHub Actions から実行する想定。
# 目的:
# - ECR に push した新しい image を使って ECS task definition を新規登録
# - ECS service を新task definitionに更新し、安定化まで待つ
#
# 重要:
# - terraform 側で aws_ecs_service.task_definition を ignore_changes している前提。
#   そうでないと、次の terraform apply で task_definition が巻き戻される。

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

CLUSTER_NAME="${1:?cluster name required}"
SERVICE_NAME="${2:?service name required}"
TASK_FAMILY="${3:?task definition family required}"
CONTAINER_NAME="${4:?container name required}"
NEW_IMAGE="${5:?new image required}"

TMPFILE="$(mktemp).taskdef.json"

echo "Fetching current task definition for family: ${TASK_FAMILY}"
aws ecs describe-task-definition --task-definition "${TASK_FAMILY}" \
  | jq '.taskDefinition
        | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
        | (.containerDefinitions[] | select(.name=="'"${CONTAINER_NAME}"'") | .image) = "'"${NEW_IMAGE}"'"' \
  > "${TMPFILE}"

echo "Registering new task definition..."
NEW_TASK_ARN="$(aws ecs register-task-definition --cli-input-json "file://${TMPFILE}" \
  | jq -r '.taskDefinition.taskDefinitionArn')"

echo "Updating service ${SERVICE_NAME} to task definition ${NEW_TASK_ARN}"
aws ecs update-service --cluster "${CLUSTER_NAME}" --service "${SERVICE_NAME}" --task-definition "${NEW_TASK_ARN}" >/dev/null

echo "Waiting for service to become stable..."
aws ecs wait services-stable --cluster "${CLUSTER_NAME}" --services "${SERVICE_NAME}"

echo "Done"
