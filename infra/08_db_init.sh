#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] Apply DB schema ==="
  DP="${ROOT}/infra/out/${REGION}/dataplane.json"
  if [[ ! -f "$DP" ]]; then
    echo "  ! dataplane.json not found for ${REGION}. Run 'make 03-dataplane' first."
    exit 1
  fi
  TARGET_REGION="$REGION" DATAPLANE_FILE="$DP" node "${ROOT}/tools/db/init.js"
done
