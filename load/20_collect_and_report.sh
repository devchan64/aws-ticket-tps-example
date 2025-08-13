#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

mkdir -p "${ROOT}/load/out"
TOTAL_SENT=0; TOTAL_OK=0; TOTAL_ERR=0
P50S=(); P95S=(); P99S=(); AVGS=()

for REGION in "${REGIONS[@]}"; do
  BUCKET="${LOAD_S3_BUCKET_PREFIX}-${REGION}"
  mkdir -p "${ROOT}/load/out/${REGION}"
  aws s3 sync s3://${BUCKET}/ "${ROOT}/load/out/${REGION}/" --delete --region "$REGION" --profile "$AWS_PROFILE" >/dev/null || true

  for f in "${ROOT}/load/out/${REGION}"/result-*.json; do
    [[ -f "$f" ]] || continue
    SENT=$(jq '.sent' "$f"); OK=$(jq '.ok' "$f"); ERR=$(jq '.err' "$f")
    P50=$(jq '.p50' "$f"); P95=$(jq '.p95' "$f"); P99=$(jq '.p99' "$f"); AVG=$(jq '.avg' "$f")
    TOTAL_SENT=$((TOTAL_SENT + SENT)); TOTAL_OK=$((TOTAL_OK + OK)); TOTAL_ERR=$((TOTAL_ERR + ERR))
    P50S+=("$P50"); P95S+=("$P95"); P99S+=("$P99"); AVGS+=("$AVG")
  done
done

avg_array () { awk '{s+=$1} END { if (NR>0) printf "%.2f\n", s/NR; else print 0 }'; }
P50_MEAN=$(printf "%s\n" "${P50S[@]:-}" | avg_array)
P95_MEAN=$(printf "%s\n" "${P95S[@]:-}" | avg_array)
P99_MEAN=$(printf "%s\n" "${P99S[@]:-}" | avg_array)
AVG_MEAN=$(printf "%s\n" "${AVGS[@]:-}" | avg_array)

cat > "${ROOT}/load/report.md" <<EOF
# Load Test Report

- Total sent: ${TOTAL_SENT}
- Total ok: ${TOTAL_OK}
- Total err: ${TOTAL_ERR}
- Avg p50: ${P50_MEAN} ms
- Avg p95: ${P95_MEAN} ms
- Avg p99: ${P99_MEAN} ms
- Avg latency: ${AVG_MEAN} ms

Notes:
- Per-worker results are average-aggregated. For strict percentiles across all samples, collect raw latencies or histogram bins.
- Scenario: default is mix(70% public / 30% confirm). Edit load/scenarios/*.yaml to change.
EOF

echo "✔ Report: load/report.md"
