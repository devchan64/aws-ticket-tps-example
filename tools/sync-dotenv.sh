#!/usr/bin/env bash
# tools/sync-dotenv.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/env.sh"

# e2e .env
cat > "${ROOT}/test/e2e/.env" <<EOF
REGION=${REGIONS[0]}
INFRA_OUT=../../infra/out
# BASE_URL=              # 비워두면 resolve-alb-dns.js가 자동 주입
USER_ID=user-0001
EVENT_ID=event-0001
SEAT_IDS=R1C1,R1C2
EOF

# loadtestbot .env
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

echo "[sync] wrote test/e2e/.env and test/loadtestbot/.env"
