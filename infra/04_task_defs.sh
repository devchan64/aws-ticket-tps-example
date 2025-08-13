#!/usr/bin/env bash
#
# infra/04_task_defs.sh
#
set -euo pipefail

# Register ECS Task Definitions (public-api, confirm-api, confirm-worker)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] Register task definitions (public / confirm / worker) ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  if [[ ! -f "${OUTDIR}/cluster.json" ]]; then
    echo "❌ ${OUTDIR}/cluster.json not found. Run infra/02_cluster_and_roles.sh first."
    exit 1
  fi
  EXEC_ROLE="$(jq -r .ExecutionRoleArn "${OUTDIR}/cluster.json")"
  PUB_ROLE="$(jq -r .PublicTaskRoleArn "${OUTDIR}/cluster.json")"
  CON_ROLE="$(jq -r .ConfirmTaskRoleArn "${OUTDIR}/cluster.json")"

  if [[ -f "${OUTDIR}/dataplane.json" ]]; then
    SQS_URL="$(jq -r .QueueUrl "${OUTDIR}/dataplane.json")"
    REDIS_ENDPOINT="$(jq -r .RedisEndpoint "${OUTDIR}/dataplane.json")"
    AURORA_ENDPOINT="$(jq -r .AuroraWriterEndpoint "${OUTDIR}/dataplane.json")"
    AURORA_SECRET_ARN="$(jq -r .AuroraSecretArn "${OUTDIR}/dataplane.json")"
    AURORA_DB_NAME_OUT="$(jq -r .AuroraDbName "${OUTDIR}/dataplane.json")"
    [[ "${SQS_URL}" == "null" ]] && SQS_URL=""
    [[ "${REDIS_ENDPOINT}" == "null" ]] && REDIS_ENDPOINT=""
    [[ "${AURORA_ENDPOINT}" == "null" ]] && AURORA_ENDPOINT=""
    [[ "${AURORA_SECRET_ARN}" == "null" ]] && AURORA_SECRET_ARN=""
    [[ "${AURORA_DB_NAME_OUT}" == "null" || -z "${AURORA_DB_NAME_OUT}" ]] && AURORA_DB_NAME_OUT="${AURORA_DB_NAME:-ticketdb}"
  else
    SQS_URL=""
    REDIS_ENDPOINT=""
    AURORA_ENDPOINT=""
    AURORA_SECRET_ARN=""
    AURORA_DB_NAME_OUT="${AURORA_DB_NAME:-ticketdb}"
  fi

  aws logs create-log-group --log-group-name "/ecs/ticket-public"  --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  aws logs create-log-group --log-group-name "/ecs/ticket-confirm" --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  aws logs create-log-group --log-group-name "/ecs/ticket-worker"  --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  cat > "${OUTDIR}/td-public.json" <<JSON
{
  "family": "ticket-public",
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
  "requiresCompatibilities": ["FARGATE"],
  "executionRoleArn": "${EXEC_ROLE}",
  "taskRoleArn": "${PUB_ROLE}",
  "containerDefinitions": [{
    "name": "public",
    "image": "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PUBLIC_REPO}:prod",
    "portMappings": [{ "containerPort": 3000, "protocol": "tcp" }],
    "environment": [
      { "name": "NODE_ENV", "value": "production" },
      { "name": "PORT", "value": "3000" },
      { "name": "REDIS_HOST", "value": "${REDIS_ENDPOINT}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/ticket-public",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true
  }]
}
JSON

  aws ecs register-task-definition \
    --cli-input-json file://"${OUTDIR}/td-public.json" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  cat > "${OUTDIR}/td-confirm.json" <<JSON
{
  "family": "ticket-confirm",
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
  "requiresCompatibilities": ["FARGATE"],
  "executionRoleArn": "${EXEC_ROLE}",
  "taskRoleArn": "${CON_ROLE}",
  "containerDefinitions": [{
    "name": "confirm",
    "image": "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_CONFIRM_REPO}:prod",
    "portMappings": [{ "containerPort": 3000, "protocol": "tcp" }],
    "environment": [
      { "name": "NODE_ENV", "value": "production" },
      { "name": "PORT", "value": "3000" },
      { "name": "DB_HOST", "value": "${AURORA_ENDPOINT}" },
      { "name": "DB_NAME", "value": "${AURORA_DB_NAME_OUT}" },
      { "name": "SQS_URL", "value": "${SQS_URL}" },
      { "name": "SQS_GROUP_SHARDS", "value": "1024" }
    ],
    "secrets": [
      { "name": "DB_SECRET_JSON", "valueFrom": "${AURORA_SECRET_ARN}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/ticket-confirm",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true
  }]
}
JSON

  aws ecs register-task-definition \
    --cli-input-json file://"${OUTDIR}/td-confirm.json" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  cat > "${OUTDIR}/td-worker.json" <<JSON
{
  "family": "ticket-worker",
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
  "requiresCompatibilities": ["FARGATE"],
  "executionRoleArn": "${EXEC_ROLE}",
  "taskRoleArn": "${CON_ROLE}",
  "containerDefinitions": [{
    "name": "worker",
    "image": "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_WORKER_REPO:-confirm-worker}:prod",
    "environment": [
      { "name": "AWS_REGION", "value": "${REGION}" },
      { "name": "SQS_URL", "value": "${SQS_URL}" },
      { "name": "DB_HOST", "value": "${AURORA_ENDPOINT}" },
      { "name": "DB_NAME", "value": "${AURORA_DB_NAME_OUT}" },
      { "name": "BATCH", "value": "10" },
      { "name": "WAIT", "value": "10" },
      { "name": "SQS_GROUP_SHARDS", "value": "1024" },
      { "name": "SQS_LONG_POLL", "value": "20" },
      { "name": "SQS_VISIBILITY", "value": "120" },
      { "name": "CONCURRENCY", "value": "32" }
    ],
    "secrets": [
      { "name": "DB_SECRET_JSON", "valueFrom": "${AURORA_SECRET_ARN}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/ticket-worker",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "essential": true
  }]
}
JSON

  aws ecs register-task-definition \
    --cli-input-json file://"${OUTDIR}/td-worker.json" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  echo "✔ [$REGION] task defs registered (ticket-public / ticket-confirm / ticket-worker)"
done
