#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] Data plane: SQS + DDB + (Redis) + (Aurora) ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  # ---------- SQS ----------
  aws sqs create-queue --queue-name ticket-confirm-dlq.fifo \
    --attributes FifoQueue=true --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  DLQ_URL=$(aws sqs get-queue-url --queue-name ticket-confirm-dlq.fifo --region "$REGION" --profile "$AWS_PROFILE" --query QueueUrl --output text)
  DLQ_ARN=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --region "$REGION" --profile "$AWS_PROFILE" --query 'Attributes.QueueArn' --output text)

  aws sqs create-queue --queue-name ticket-confirm.fifo \
    --attributes "FifoQueue=true,ContentBasedDeduplication=true,RedrivePolicy={\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"3\"}" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  QURL=$(aws sqs get-queue-url --queue-name ticket-confirm.fifo --region "$REGION" --profile "$AWS_PROFILE" --query QueueUrl --output text)

  # ---------- DDB ----------
  aws dynamodb create-table --table-name ticket_seat_lock \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true
  aws dynamodb update-time-to-live --table-name ticket_seat_lock \
    --time-to-live-specification "Enabled=true, AttributeName=expires_at" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

  # ---------- Redis (ElastiCache, 옵션) ----------
  REDIS_ENDPOINT=""
  if [[ "${ENABLE_REDIS}" == "true" ]]; then
    echo "-> Creating Redis (cluster mode) ..."
    # 값 로드
    eval "VPC_ID=\$VPC_ID_${REGION//-/_}"
    eval "PRI_SUBNETS=\$PRI_SUBNETS_${REGION//-/_}"
    eval "REDIS_SG=\$REDIS_SG_${REGION//-/_}"

    # Subnet group
    IFS=',' read -r -a PRIS <<< "$PRI_SUBNETS"
    aws elasticache create-cache-subnet-group \
      --cache-subnet-group-name "ticket-redis-${REGION//-}" \
      --cache-subnet-group-description "ticket redis" \
      --subnet-ids "${PRIS[@]}" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

    # RG (Cluster Mode Enabled)
    aws elasticache create-replication-group \
      --replication-group-id "ticket-redis-${REGION//-}" \
      --description "ticket redis" \
      --engine redis \
      --engine-version 7.0 \
      --cache-node-type "${REDIS_NODE_TYPE}" \
      --cache-subnet-group-name "ticket-redis-${REGION//-}" \
      --security-group-ids "$REDIS_SG" \
      --transit-encryption-enabled \
      --num-node-groups "${REDIS_NODE_GROUPS}" \
      --replicas-per-node-group "${REDIS_REPLICAS_PER_GROUP}" \
      --automatic-failover-enabled \
      --at-rest-encryption-enabled \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

    echo "   waiting Redis available..."
    aws elasticache wait replication-group-available \
      --replication-group-id "ticket-redis-${REGION//-}" \
      --region "$REGION" --profile "$AWS_PROFILE"

    REDIS_ENDPOINT=$(aws elasticache describe-replication-groups \
      --replication-group-id "ticket-redis-${REGION//-}" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query 'ReplicationGroups[0].ConfigurationEndpoint.Address' --output text)
  fi

  # ---------- Aurora PostgreSQL Serverless v2 (옵션) ----------
  AURORA_WRITER_ENDPOINT=""
  AURORA_SECRET_ARN=""
  if [[ "${ENABLE_AURORA}" == "true" ]]; then
    echo "-> Creating Aurora PostgreSQL Serverless v2 ..."
    eval "PRI_SUBNETS=\$PRI_SUBNETS_${REGION//-/_}"
    eval "RDS_SG=\$RDS_SG_${REGION//-/_}"
    IFS=',' read -r -a PRIS <<< "$PRI_SUBNETS"

    # DB Subnet group
    aws rds create-db-subnet-group \
      --db-subnet-group-name "ticket-rds-${REGION//-}" \
      --db-subnet-group-description "ticket rds" \
      --subnet-ids "${PRIS[@]}" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

    # Admin Secret (Secrets Manager)
    RANDPW=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 24)
    AURORA_SECRET_ARN=$(aws secretsmanager create-secret \
      --name "ticket/rds/${REGION}/admin" \
      --description "Aurora admin credentials" \
      --secret-string "{\"username\":\"${AURORA_ADMIN_USER}\",\"password\":\"${RANDPW}\"}" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query 'ARN' --output text 2>/dev/null || aws secretsmanager describe-secret --secret-id "ticket/rds/${REGION}/admin" --region "$REGION" --profile "$AWS_PROFILE" --query 'ARN' --output text)

    # Cluster (serverless v2)
    aws rds create-db-cluster \
      --db-cluster-identifier "ticket-aurora-${REGION//-}" \
      --engine aurora-postgresql \
      --engine-version "${AURORA_ENGINE_VERSION}" \
      --db-subnet-group-name "ticket-rds-${REGION//-}" \
      --vpc-security-group-ids "$RDS_SG" \
      --master-username "${AURORA_ADMIN_USER}" \
      --master-user-password "${RANDPW}" \
      --database-name "${AURORA_DB_NAME}" \
      --enable-http-endpoint \
      --serverless-v2-scaling-configuration MinCapacity=${AURORA_MIN_ACU},MaxCapacity=${AURORA_MAX_ACU} \
      --storage-encrypted \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

    echo "   waiting DB cluster available..."
    aws rds wait db-cluster-available \
      --db-cluster-identifier "ticket-aurora-${REGION//-}" \
      --region "$REGION" --profile "$AWS_PROFILE"

    # Writer 인스턴스 (db.serverless)
    aws rds create-db-instance \
      --db-cluster-identifier "ticket-aurora-${REGION//-}" \
      --db-instance-identifier "ticket-aurora-writer-${REGION//-}" \
      --db-instance-class db.serverless \
      --engine aurora-postgresql \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || true

    echo "   waiting DB instance available..."
    aws rds wait db-instance-available \
      --db-instance-identifier "ticket-aurora-writer-${REGION//-}" \
      --region "$REGION" --profile "$AWS_PROFILE"

    AURORA_WRITER_ENDPOINT=$(aws rds describe-db-clusters \
      --db-cluster-identifier "ticket-aurora-${REGION//-}" \
      --region "$REGION" --profile "$AWS_PROFILE" \
      --query 'DBClusters[0].Endpoint' --output text)
  fi

  # ---------- OUTPUT ----------
  cat > "${OUTDIR}/dataplane.json" <<JSON
{
  "QueueUrl": "${QURL}",
  "DlqUrl": "${DLQ_URL}",
  "DdbTable": "ticket_seat_lock",
  "RedisEndpoint": "${REDIS_ENDPOINT}",
  "AuroraWriterEndpoint": "${AURORA_WRITER_ENDPOINT}",
  "AuroraSecretArn": "${AURORA_SECRET_ARN}",
  "AuroraDbName": "${AURORA_DB_NAME}"
}
JSON

  echo "✔ [$REGION] Data plane ready."
done
