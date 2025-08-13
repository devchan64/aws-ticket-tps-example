#!/usr/bin/env bash
set -euo pipefail

# ECS 클러스터, IAM 역할(Execution/Task), 로그그룹 베이스

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] cluster & roles ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  # ECS cluster
  CLUSTER_ARN=$(aws ecs create-cluster --cluster-name "ticket-${REGION}" \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'cluster.clusterArn' --output text)

  # IAM roles
  EXEC_ROLE_NAME="ticketEcsExecutionRole"
  TASK_PUBLIC_ROLE="ticketPublicTaskRole"
  TASK_CONFIRM_ROLE="ticketConfirmTaskRole"

  aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  aws iam attach-role-policy --role-name "$EXEC_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null || true

  aws iam get-role --role-name "$TASK_PUBLIC_ROLE" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$TASK_PUBLIC_ROLE" \
    --assume-role-policy-document '{
      "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null

  aws iam get-role --role-name "$TASK_CONFIRM_ROLE" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$TASK_CONFIRM_ROLE" \
    --assume-role-policy-document '{
      "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null

  # 권한(SecretsManager/SQS/RDS/DDB/ElastiCache 등 필수 최소 권한 정책은 프로젝트 정책에 맞게 추가)
  # 예시: aws iam attach-role-policy --role-name "$TASK_CONFIRM_ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess

  cat > "${OUTDIR}/cluster.json" <<JSON
{"ClusterArn":"${CLUSTER_ARN}",
 "ExecutionRoleArn":"arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE_NAME}",
 "PublicTaskRoleArn":"arn:aws:iam::${ACCOUNT_ID}:role/${TASK_PUBLIC_ROLE}",
 "ConfirmTaskRoleArn":"arn:aws:iam::${ACCOUNT_ID}:role/${TASK_CONFIRM_ROLE}"}
JSON

  echo "✔ [$REGION] cluster & roles ready"
done
