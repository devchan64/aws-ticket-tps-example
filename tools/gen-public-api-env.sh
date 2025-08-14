#!/usr/bin/env bash
# tools/gen-public-api-env.sh
set -euo pipefail

# 프로젝트 공통 환경 불러오기
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${ROOT_DIR}/env.sh"

TARGET_ENV_FILE="${ROOT_DIR}/apps/public-api/.env"

# .env 파일 생성
cat > "$TARGET_ENV_FILE" <<EOF
# Generated at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
NODE_ENV=production
PORT=${FASTIFY_PORT}
HOST=${FASTIFY_HOST}
LOG_LEVEL=${LOG_LEVEL}

# Redis
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_TLS=${REDIS_TLS}
REDIS_AUTH_TOKEN=${REDIS_AUTH_TOKEN}
REDIS_REQUIRED=${REDIS_REQUIRED}

# Postgres
PG_URI=${PG_URI}

# SQS
SQS_URL=${SQS_URL}

# Metadata
SERVICE_NAME=${SERVICE_NAME}
SERVICE_VERSION=${SERVICE_VERSION}
EOF

echo "[gen-public-api-env] Wrote $(realpath "$TARGET_ENV_FILE")"
