#!/usr/bin/env bash
# tools/gen-loadtestbot-env.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/env.sh"

# loadtestbot .env 생성
_regions_csv="$(IFS=,; echo "${REGIONS[*]}")"
cat > "${ROOT}/test/loadtestbot/.env" <<EOF
REGIONS=${_regions_csv}
INFRA_OUT=../../infra/out
RATE=${LOAD_TARGET_RPS_PER_WORKER}
DURATION=${LOAD_DURATION_SEC}s
RAMP_UP=60s
THRESH_P95_MS=200
THRESH_ERR_RATE=0.01

# ECS / 네트워크 (필요시 채우기)
ECS_CLUSTER=aws-ticket-tps
ECS_TASKDEF_FAMILY=aws-ticket-tps-k6
ECS_TASK_SUBNETS=
ECS_TASK_SGS=
ECS_ASSIGN_PUBLIC_IP=ENABLED

# 로그 그룹
K6_LOG_GROUP=/ecs/loadtestbot
K6_LOG_PREFIX=load-k6
EOF

echo "[gen-loadtestbot-env] wrote test/loadtestbot/.env"
