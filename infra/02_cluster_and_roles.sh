#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] ECS cluster / IAM / Logs ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  # 1) CloudWatch 로그 그룹
  for LG in "/ecs/ticket-public" "/ecs/ticket-confirm"; do
    aws logs create-log-group --log-group-name "$LG" --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
    aws logs tag-log-group --log-group-name "$LG" --tags Project=ticket --region "$REGION" --profile "$AWS_PROFILE" || true
  done

  # 2) IAM 역할: ECS task execution role
  EXE_ROLE_ARN=$(aws iam get-role --role-name ticketEcsTaskExecutionRole --query 'Role.Arn' --output text 2>/dev/null || true)
  if [[ -z "${EXE_ROLE_ARN}" ]]; then
    aws iam create-role --role-name ticketEcsTaskExecutionRole \
      --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
      }' --profile "$AWS_PROFILE" >/dev/null
    aws iam attach-role-policy --role-name ticketEcsTaskExecutionRole \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
      --profile "$AWS_PROFILE"
    EXE_ROLE_ARN=$(aws iam get-role --role-name ticketEcsTaskExecutionRole --query 'Role.Arn' --output text --profile "$AWS_PROFILE")
  fi

  # 3) IAM 역할: app task roles (권한 최소, confirm은 SQS 전송 필요할 수 있음)
  for ROLE in ticketPublicTaskRole ticketConfirmTaskRole; do
    ARN=$(aws iam get-role --role-name $ROLE --query 'Role.Arn' --output text 2>/dev/null || true)
    if [[ -z "$ARN" ]]; then
      aws iam create-role --role-name $ROLE \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
        }' --profile "$AWS_PROFILE" >/dev/null
    fi
  done

  # confirm용 SQS 최소권한 정책(큐 이름은 dataplane 단계에서 생성하지만 미리 와일드카드 허용 가능)
  cat > "${OUTDIR}/confirm-sqs-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["sqs:SendMessage"],"Resource":"arn:aws:sqs:${REGION}:${ACCOUNT_ID}:ticket-*"}
  ]
}
EOF
  aws iam put-role-policy --role-name ticketConfirmTaskRole --policy-name ticketConfirmSQSSend \
    --policy-document file://"${OUTDIR}/confirm-sqs-policy.json" --profile "$AWS_PROFILE"

  # 4) ECS 클러스터
  aws ecs create-cluster --clusterName "ticket-${REGION}" \
    --tags key=Project,value=ticket key=Region,value=${REGION} \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  cat > "${OUTDIR}/cluster.json" <<JSON
{ "ClusterName": "ticket-${REGION}",
  "ExecutionRoleArn": "${EXE_ROLE_ARN}",
  "PublicTaskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ticketPublicTaskRole",
  "ConfirmTaskRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ticketConfirmTaskRole"
}
JSON

  echo "✔ [$REGION] cluster and roles ready."
done
