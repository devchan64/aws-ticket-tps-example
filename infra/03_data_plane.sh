#!/usr/bin/env bash
set -euo pipefail

# 데이터 플레인: SQS(FIFO+DLQ+HT), DynamoDB(TTL), (옵션)Redis, (옵션)Aurora Serverless v2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] data plane ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  # SQS: DLQ + FIFO(HT)
  DLQ_ARN=$(aws sqs create-queue --queue-name ticket-deadletter.fifo --attributes FifoQueue=true,ContentBasedDeduplication=true \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'QueueArn' --output text)
  QURL=$(aws sqs create-queue --queue-name ticket-confirm.fifo --attributes \
    FifoQueue=true,ContentBasedDeduplication=true,DeduplicationScope=messageGroup,ThroughputLimit=perMessageGroupId,RedrivePolicy="{\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"5\"}" \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'QueueUrl' --output text)

  # DynamoDB: 좌석 잠금 테이블
  aws dynamodb create-table --table-name ticket-seat-lock \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null || true
  aws dynamodb update-time-to-live --table-name ticket-seat-lock \
    --time-to-live-specification "Enabled=true, AttributeName=ttl" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  # Redis (선택)
  REDIS_ENDPOINT=""
  if [[ "${ENABLE_REDIS:-true}" == "true" ]]; then
    # 이미 존재하면 describe로 엔드포인트 획득하는 로직을 두는 것이 안전하나, 예제에선 단순 생성 가정
    # 생성은 콘솔/사전 준비를 권장. 여기선 엔드포인트를 env에서 받거나 생략.
    REDIS_ENDPOINT="${REDIS_ENDPOINT_OVERRIDE:-}"
  fi

  # Aurora (선택)
  AURORA_WRITER=""
  AURORA_SECRET_ARN=""
  if [[ "${ENABLE_AURORA:-true}" == "true" ]]; then
    # 프로젝트 상황에 맞춘 클러스터 생성을 별도 스크립트로 분리하는 것을 권장.
    # 여기서는 이미 생성된 값을 env에서 받는 형태를 기본으로 둠.
    AURORA_WRITER="${AURORA_WRITER_OVERRIDE:-}"
    AURORA_SECRET_ARN="${AURORA_SECRET_ARN_OVERRIDE:-}"
  fi

  cat > "${OUTDIR}/dataplane.json" <<JSON
{"QueueUrl":"${QURL}",
 "RedisEndpoint":"${REDIS_ENDPOINT}",
 "AuroraWriterEndpoint":"${AURORA_WRITER}",
 "AuroraSecretArn":"${AURORA_SECRET_ARN}",
 "AuroraDbName":"${AURORA_DB_NAME:-ticketdb}"}
JSON

  echo "✔ [$REGION] dataplane ready"
done
