#!/usr/bin/env bash
# apps/confirm-worker/gen-confirm-env.sh
set -euo pipefail

# 프로젝트 루트 경로
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# .env 파일은 confirm-worker 디렉토리 안에 생성
ENV_FILE="$(cd "$(dirname "$0")" && pwd)/.env"

# 루트 env.sh 로드
source "${ROOT}/env.sh"

# .env 생성
{
  echo "# Generated on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "# from ${ROOT}/env.sh"
  export -p | awk '{print $3}' | while IFS='=' read -r key value; do
    # 작은따옴표 제거
    value="${value#"\'"}"
    value="${value%"\'"}"
    echo "${key}=${value}"
  done
} > "${ENV_FILE}"

echo "[gen-confirm-env] .env file generated at ${ENV_FILE}"
