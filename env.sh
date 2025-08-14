#!/usr/bin/env bash
# env.sh
set -euo pipefail

# ===== Project-wide =====
export TAG_PREFIX="${TAG_PREFIX:-ticket}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
# 테스트 대상 리전 (배열)
export REGIONS=("ap-northeast-1" "ap-northeast-2")
# 주 리전(없으면 REGIONS[0])
export PRIMARY_REGION="${PRIMARY_REGION:-${REGIONS[0]}}"

# 가능하면 AWS Account ID 자동 감지 (미설정 시)
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")}"

# ===== VPC CIDR (region-scoped; do not overlap) =====
export VPC_CIDR_ap_northeast_1="${VPC_CIDR_ap_northeast_1:-10.11.0.0/16}"
export VPC_CIDR_ap_northeast_2="${VPC_CIDR_ap_northeast_2:-10.12.0.0/16}"

# ===== Subnet plan (comma-separated; parsed by scripts) =====
# Example: three /20 public and three /20 private subnets per region (AZ=3)
export PUB_BLOCKS="${PUB_BLOCKS:-/20,/20,/20}"
export PRI_BLOCKS="${PRI_BLOCKS:-/20,/20,/20}"

# ===== ECR Repos =====
export ECR_PUBLIC_REPO="${ECR_PUBLIC_REPO:-public-api}"
export ECR_CONFIRM_REPO="${ECR_CONFIRM_REPO:-confirm-api}"
export ECR_WORKER_REPO="${ECR_WORKER_REPO:-worker}"

# ===== S3 bucket (results & artifacts) =====
# 최종 버킷명은 스크립트에서: ${LOAD_S3_BUCKET_PREFIX}-${AWS_REGION}-${AWS_ACCOUNT_ID}
export LOAD_S3_BUCKET_PREFIX="${LOAD_S3_BUCKET_PREFIX:-ticket-load-results}"

# ===== Load generator (common) =====
# NOTE: 목표 p95=0.2s 기준, 동시성 >= RPS*0.2 필요
export LOAD_DURATION_SEC="${LOAD_DURATION_SEC:-60}"
export LOAD_TARGET_RPS_PER_WORKER="${LOAD_TARGET_RPS_PER_WORKER:-4000}"
export LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-1000}"  # 최소 800 이상 권장

# ----- Per-region workers (tune to reach 100k TPS) -----
# 옵션 A: 13 + 12 = 25 workers @ 4k RPS -> 100k
export LOAD_WORKERS_ap_northeast_1="${LOAD_WORKERS_ap_northeast_1:-13}"
export LOAD_WORKERS_ap_northeast_2="${LOAD_WORKERS_ap_northeast_2:-12}"

# ===== Redis (optional) =====
export ENABLE_REDIS="${ENABLE_REDIS:-true}"           # "true"/"false"
export REDIS_NODE_GROUPS="${REDIS_NODE_GROUPS:-3}"    # shards (cluster mode)
export REDIS_REPLICAS_PER_GROUP="${REDIS_REPLICAS_PER_GROUP:-1}"
export REDIS_NODE_TYPE="${REDIS_NODE_TYPE:-cache.r7g.large}"

# ===== Aurora PostgreSQL Serverless v2 =====
export ENABLE_AURORA="${ENABLE_AURORA:-true}"         # "true"/"false"
export AURORA_ENGINE_VERSION="${AURORA_ENGINE_VERSION:-15.4}"
export AURORA_DB_NAME="${AURORA_DB_NAME:-ticketdb}"
export AURORA_ADMIN_USER="${AURORA_ADMIN_USER:-ticketadmin}"
export AURORA_MIN_ACU="${AURORA_MIN_ACU:-2}"          # 2~(계정 한도 내)
export AURORA_MAX_ACU="${AURORA_MAX_ACU:-128}"        # 상향 테스트 여지 확보

# ===== Optional: ALB/CloudFront/KMS/X-Ray toggles =====
export ENABLE_XRAY="${ENABLE_XRAY:-true}"
export ENABLE_CLOUDFRONT="${ENABLE_CLOUDFRONT:-true}"
export ACM_CERT_ARN_ap_northeast_1="${ACM_CERT_ARN_ap_northeast_1:-}" # 필요 시 지정
export ACM_CERT_ARN_ap_northeast_2="${ACM_CERT_ARN_ap_northeast_2:-}"
export KMS_KEY_ID_LOGS="${KMS_KEY_ID_LOGS:-}"         # CloudWatch Logs/Kinesis 등
export KMS_KEY_ID_SECRETS="${KMS_KEY_ID_SECRETS:-}"   # Secrets Manager

# ===== Build/Deploy =====
export IMAGE_TAG="${IMAGE_TAG:-latest}"
export BUILD_DATE="${BUILD_DATE:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"
export GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')}"

# ===== Service Endpoints (optional; 문서/테스트 편의) =====
export PUBLIC_API_URL="${PUBLIC_API_URL:-https://public.example.com}"
export CONFIRM_API_URL="${CONFIRM_API_URL:-https://confirm.example.com}"
export WORKER_API_URL="${WORKER_API_URL:-https://worker.example.com}"

# ===== Shared Service Connections (local/CI 공통) =====
# 주의: 실제 배포환경에선 SSM/Secrets Manager 사용 권장
export PG_URI="${PG_URI:-postgresql://user:pass@host:5432/ticketdb}"
# SQS URL 기본값: PRIMARY_REGION 기준
export SQS_URL="${SQS_URL:-https://sqs.${PRIMARY_REGION}.amazonaws.com/${AWS_ACCOUNT_ID:-000000000000}/ticket-queue.fifo}"
export REDIS_HOST="${REDIS_HOST:-redis.example.com}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_TLS="${REDIS_TLS:-true}"
export REDIS_AUTH_TOKEN="${REDIS_AUTH_TOKEN:-changeme}"

# ===== Monitoring / Logging =====
export ENABLE_METRICS="${ENABLE_METRICS:-true}"
export ENABLE_TRACING="${ENABLE_TRACING:-true}"
export LOG_LEVEL="${LOG_LEVEL:-info}"

# ===== Load Test Tuning =====
export LOAD_WARMUP_SEC="${LOAD_WARMUP_SEC:-10}"
export LOAD_RAMPUP_SEC="${LOAD_RAMPUP_SEC:-15}"

# ===== Service Metadata =====
export SERVICE_NAME="${SERVICE_NAME:-public-api}"
export SERVICE_VERSION="${SERVICE_VERSION:-1.0.0}"

# ===== Fastify Server =====
export FASTIFY_PORT="${FASTIFY_PORT:-3000}"
export FASTIFY_HOST="${FASTIFY_HOST:-0.0.0.0}"

# ===== Redis Required Flag =====
export REDIS_REQUIRED="${REDIS_REQUIRED:-false}"  # 운영은 true 권장

# ===== HTTP Proxy / Timeout =====
export TRUST_PROXY="${TRUST_PROXY:-true}"                 # Fastify trustProxy
export REQUEST_TIMEOUT_MS="${REQUEST_TIMEOUT_MS:-30000}"  # 30s

# ===== Healthcheck (ops) =====
export HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-/public/health}"
export HEALTHCHECK_INTERVAL_SEC="${HEALTHCHECK_INTERVAL_SEC:-30}"

# ===== Derived / sanity checks (informational) =====
_total_workers=0
for r in "${REGIONS[@]}"; do
  var="LOAD_WORKERS_${r//-/_}"
  _count="${!var:-0}"
  _total_workers=$(( _total_workers + _count ))
done

# 총 목표 TPS 계산
_target_rps="${LOAD_TARGET_RPS_PER_WORKER}"
_total_tps=$(( _total_workers * _target_rps ))

# 간단 출력 (스크립트 상단에서 source 시 가시성)
echo "[env] Regions: ${REGIONS[*]} (primary=${PRIMARY_REGION})"
[[ -n "${AWS_ACCOUNT_ID}" ]] && echo "[env] AWS Account: ${AWS_ACCOUNT_ID}" || echo "[env][warn] AWS_ACCOUNT_ID is empty"
echo "[env] Workers total: ${_total_workers} (per-worker RPS=${_target_rps}) -> Target TPS=${_total_tps}"
echo "[env] Concurrency per worker: ${LOAD_CONCURRENCY} (p95 target 0.2s -> need >= RPS*0.2)"
if [[ "${_total_tps}" -lt 100000 ]]; then
  echo "[env][warn] Target TPS < 100k. Consider increasing workers or per-worker RPS." >&2
fi
echo "[env] SQS_URL=${SQS_URL}"

# 문자열 boolean helper (스크립트에서 [[ \"\$(to_bool \"$ENABLE_REDIS\")\" == \"true\" ]] 형태로 사용)
to_bool() {
  case "${1,,}" in
    true|1|yes|y) echo "true" ;;
    *) echo "false" ;;
  esac
}
export -f to_bool
