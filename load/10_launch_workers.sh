#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

# 결과 저장용 버킷을 리전마다 준비
for REGION in "${REGIONS[@]}"; do
  BUCKET="${LOAD_S3_BUCKET_PREFIX}-${REGION}"
  if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" || true
  fi
done

# ALB DNS 가져오기
declare -A ALB_DNS
for REGION in "${REGIONS[@]}"; do
  J="${ROOT}/infra/out/${REGION}/alb.json"
  if [[ ! -f "$J" ]]; then
    echo "ALB not found in ${REGION}. Run infra/03_alb_services.sh first."; exit 1
  fi
  ALB_DNS[$REGION]=$(jq -r .DNSName "$J")
done

# AMI (Amazon Linux 2023)
get_ami() {
  local REGION="$1"
  aws ec2 describe-images \
    --owners "137112412989" \
    --filters "Name=name,Values=al2023-ami-*" "Name=architecture,Values=x86_64" "Name=state,Values=available" \
    --query "Images|sort_by(@,&CreationDate)[-1].ImageId" \
    --region "$REGION" --output text
}

# SG: 아웃바운드만 필요하면 기본 VPC SG 사용 가능 / 여기선 새로 만들지 않음
# 서브넷: 퍼블릭 서브넷 중 첫 번째를 사용
launch_workers() {
  local REGION="$1"
  local COUNT_VAR="LOAD_WORKERS_${REGION//-/_}"
  local COUNT="${!COUNT_VAR}"
  [[ -z "$COUNT" ]] && COUNT=10

  local PUBS_VAR="PUB_SUBNETS_${REGION//-/_}"
  IFS=',' read -r -a PUBS <<< "$(eval echo \$$PUBS_VAR)"
  local SUBNET_ID="${PUBS[0]}"
  local AMI_ID=$(get_ami "$REGION")
  local BUCKET="${LOAD_S3_BUCKET_PREFIX}-${REGION}"
  local PUBLIC_BASE="https://${ALB_DNS[$REGION]}/public"
  local CONFIRM_BASE="https://${ALB_DNS[$REGION]}"

  # UserData: Node 설치 + 봇 실행 + S3 업로드 → 종료
  read -r -d '' USERDATA <<EOF || true
#!/bin/bash
set -eux
dnf install -y nodejs git jq awscli
mkdir -p /opt/ticket && cd /opt/ticket
cat > scenario.yaml <<'SCN'
$(cat "${ROOT}/load/scenarios/scenario_mix_70_30.yaml")
SCN

cat > package.json <<'PKG'
$(cat "${ROOT}/load/worker_ec2/package.json")
PKG

cat > bot.js <<'BOT'
$(sed 's/\\/\\\\/g; s/`/\\`/g' "${ROOT}/load/worker_ec2/bot.js")
BOT

npm ci
export PUBLIC_BASE="${PUBLIC_BASE}"
export CONFIRM_BASE="${CONFIRM_BASE}"
export DURATION_SEC="${LOAD_DURATION_SEC}"
export TARGET_RPS="${LOAD_TARGET_RPS_PER_WORKER}"
export CONCURRENCY="${LOAD_CONCURRENCY}"
export SCENARIO_FILE="/opt/ticket/scenario.yaml"
node bot.js > result.json || true
aws s3 cp result.json s3://${BUCKET}/result-\$(hostname)-\$(date +%s).json
shutdown -h now
EOF

  IDS=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count "$COUNT" \
    --instance-type "c7i.large" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_PREFIX}-load-worker},{Key=Project,Value=${TAG_PREFIX}}]" \
    --subnet-id "$SUBNET_ID" \
    --associate-public-ip-address \
    --iam-instance-profile Name="AmazonSSMRoleForInstancesQuickSetup" \
    --user-data "$USERDATA" \
    --region "$REGION" --profile "$AWS_PROFILE" \
    --query 'Instances[*].InstanceId' --output text)
  echo "Launched in ${REGION}: ${IDS}"
}

for REGION in "${REGIONS[@]}"; do
  launch_workers "$REGION"
done
