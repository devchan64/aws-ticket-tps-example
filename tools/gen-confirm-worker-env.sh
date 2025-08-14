#!/usr/bin/env bash
# tools/gen-confirm-worker-env.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${ROOT}/apps/confirm-worker"
ENV_FILE="${APP_DIR}/.env"

# env.sh 로드
source "${ROOT}/env.sh"

# .env 파일 생성
{
  echo "# Generated on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "# from env.sh"
  echo "AWS_REGION=${PRIMARY_REGION}"
  echo "SQS_URL=${SQS_URL}"
  echo "DB_HOST=${DB_HOST:-}"
  echo "DB_NAME=${AURORA_DB_NAME}"
  echo "DB_SECRET_JSON=${DB_SECRET_JSON:-}"
  # Worker 실행 튜닝값 (기본값 유지 가능)
  echo "BATCH_SIZE=${BATCH_SIZE:-10}"
  echo "WAIT_TIME=${WAIT_TIME:-20}"
  echo "VISIBILITY_TIMEOUT=${VISIBILITY_TIMEOUT:-60}"
} > "${ENV_FILE}"

echo "[gen-confirm-worker-env] .env file generated at ${ENV_FILE}"
