#!/usr/bin/env bash
# env.sh
set -euo pipefail

# ===== Project-wide =====
export TAG_PREFIX="${TAG_PREFIX:-ticket}"
export AWS_PROFILE="${AWS_PROFILE:-default}"
# 테스트 대상 리전 (배열)
export REGIONS=("ap-northeast-1" "ap-northeast-2")

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
export ECR_WORKER_REPO="${ECR_WORKER_REPO:-worker}"  # 추가

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
echo "[env] Regions: ${REGIONS[*]}"
echo "[env] Workers total: ${_total_workers} (per-worker RPS=${_target_rps}) -> Target TPS=${_total_tps}"
echo "[env] Concurrency per worker: ${LOAD_CONCURRENCY} (p95 target 0.2s -> need >= RPS*0.2)"
if [[ "${_total_tps}" -lt 100000 ]]; then
  echo "[env][warn] Target TPS < 100k. Consider increasing workers or per-worker RPS." >&2
fi

# 문자열 boolean helper (스크립트에서 [[ "$(to_bool "$ENABLE_REDIS")" == "true" ]] 형태로 사용)
to_bool() {
  case "${1,,}" in
    true|1|yes|y) echo "true" ;;
    *) echo "false" ;;
  esac
}
export -f to_bool
