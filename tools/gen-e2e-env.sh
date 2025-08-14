#!/usr/bin/env bash
# tools/gen-e2e-env.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${ROOT}/env.sh"

# e2e .env 생성
cat > "${ROOT}/test/e2e/.env" <<EOF
REGION=${REGIONS[0]}
INFRA_OUT=../../infra/out
# BASE_URL=              # 비워두면 resolve-alb-dns.js가 자동 주입
USER_ID=user-0001
EVENT_ID=event-0001
SEAT_IDS=R1C1,R1C2
EOF

echo "[gen-e2e-env] wrote test/e2e/.env"
