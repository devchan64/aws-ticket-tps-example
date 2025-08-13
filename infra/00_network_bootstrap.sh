#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/env.sh"

mkdir -p "${ROOT_DIR}/infra/out"

# helper: tag
tag() {
  local arn="$1"; shift
  aws resourcegroupstaggingapi tag-resources \
    --resource-arn-list "$arn" \
    --tags "$@" >/dev/null 2>&1 || true
}

for REGION in "${REGIONS[@]}"; do
  echo "=== [${REGION}] Network Bootstrap ==="
  OUTDIR="${ROOT_DIR}/infra/out/${REGION}"
  mkdir -p "${OUTDIR}"

  # 1) AZ 세 개 선택
  AZS=($(aws ec2 describe-availability-zones --region "$REGION" --filters Name=zone-type,Values=availability-zone \
        --query 'AvailabilityZones[].ZoneName' --output text))
  if [ "${#AZS[@]}" -lt 2 ]; then
    echo "Need >=2 AZs in ${REGION}"; exit 1
  fi
  # 최대 3개까지만 사용
  AZS=("${AZS[@]:0:3}")

  # 2) VPC
  VPC_CIDR_VAR="VPC_CIDR_${REGION//-/_}"
  VPC_CIDR="${!VPC_CIDR_VAR}"
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$REGION" \
           --query 'Vpc.VpcId' --output text)
  aws ec2 modify-vpc-attribute --enable-dns-support --vpc-id "$VPC_ID" --region "$REGION"
  aws ec2 modify-vpc-attribute --enable-dns-hostnames --vpc-id "$VPC_ID" --region "$REGION"
  aws ec2 create-tags --resources "$VPC_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-vpc" Key=Project,Value="${TAG_PREFIX}"

  # 3) IGW
  IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
           --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
  aws ec2 create-tags --resources "$IGW_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-igw" Key=Project,Value="${TAG_PREFIX}"

  # 4) Subnets
  I=0
  IFS=',' read -r -a PUBS <<< "${PUB_BLOCKS}"
  IFS=',' read -r -a PRIS <<< "${PRI_BLOCKS}"

  declare -a PUB_SUBNET_IDS=()
  declare -a PRI_SUBNET_IDS=()
  for AZ in "${AZS[@]}"; do
    # 계산된 CIDR: 단순히 /20씩 증가 (예시)
    PUB_CIDR_BASE=$(( I * 32 ))
    PRI_CIDR_BASE=$(( 512 + I * 32 )) # 다른 범위
    PUB_CIDR="10.${RANDOM%200}.${PUB_CIDR_BASE}.0${PUBS[$I]:-"/20"}"  # 임시 CIDR 계산(충돌 회피를 원하면 직접 지정)
    PRI_CIDR="10.${RANDOM%200}.${PRI_CIDR_BASE}.0${PRIS[$I]:-"/20"}"

    # 퍼블릭
    PUB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUB_CIDR" \
      --availability-zone "$AZ" --region "$REGION" --query 'Subnet.SubnetId' --output text)
    aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUBNET_ID" --map-public-ip-on-launch --region "$REGION"
    aws ec2 create-tags --resources "$PUB_SUBNET_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-public-${AZ}" Key=Tier,Value=public Key=Project,Value="${TAG_PREFIX}"
    PUB_SUBNET_IDS+=("$PUB_SUBNET_ID")

    # 프라이빗
    PRI_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRI_CIDR" \
      --availability-zone "$AZ" --region "$REGION" --query 'Subnet.SubnetId' --output text)
    aws ec2 create-tags --resources "$PRI_SUBNET_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-private-${AZ}" Key=Tier,Value=private Key=Project,Value="${TAG_PREFIX}"
    PRI_SUBNET_IDS+=("$PRI_SUBNET_ID")

    I=$((I+1))
  done

  # 5) NAT Gateways (각 AZ 한 개 – 고가용성, 비용 고려)
  EIPS=()
  NAT_IDS=()
  for IDX in "${!AZS[@]}"; do
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query 'AllocationId' --output text)
    EIPS+=("$EIP_ALLOC")
    NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "${PUB_SUBNET_IDS[$IDX]}" \
              --allocation-id "$EIP_ALLOC" --region "$REGION" \
              --query 'NatGateway.NatGatewayId' --output text)
    aws ec2 create-tags --resources "$NAT_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-nat-${AZS[$IDX]}" Key=Project,Value="${TAG_PREFIX}"
    NAT_IDS+=("$NAT_ID")
  done

  echo "Waiting for NAT gateways to be available..."
  for NAT in "${NAT_IDS[@]}"; do
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT" --region "$REGION"
  done

  # 6) Route Tables
  # Public RT → IGW
  PUB_RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
              --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-tags --resources "$PUB_RT_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-rt-public" Key=Project,Value="${TAG_PREFIX}"
  aws ec2 create-route --route-table-id "$PUB_RT_ID" --destination-cidr-block "0.0.0.0/0" \
      --gateway-id "$IGW_ID" --region "$REGION" >/dev/null
  for S in "${PUB_SUBNET_IDS[@]}"; do
    aws ec2 associate-route-table --route-table-id "$PUB_RT_ID" --subnet-id "$S" --region "$REGION" >/dev/null
  done

  # Private RTs per AZ → NAT
  PRI_RT_IDS=()
  for IDX in "${!PRI_SUBNET_IDS[@]}"; do
    RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" \
            --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-tags --resources "$RT_ID" --region "$REGION" \
        --tags Key=Name,Value="${TAG_PREFIX}-rt-private-${AZS[$IDX]}" Key=Project,Value="${TAG_PREFIX}"
    aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block "0.0.0.0/0" \
        --nat-gateway-id "${NAT_IDS[$IDX]}" --region "$REGION" >/dev/null
    aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "${PRI_SUBNETIDS[$IDX]:-${PRI_SUBNET_IDS[$IDX]}}" \
        --region "$REGION" >/dev/null
    PRI_RT_IDS+=("$RT_ID")
  done

  # 7) Security Groups
  # ALB SG: 80/443 인바운드 전체
  ALB_SG_ID=$(aws ec2 create-security-group \
      --group-name "${TAG_PREFIX}-alb-sg" --description "ALB SG" \
      --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" --protocol tcp --port 80  --cidr 0.0.0.0/0 --region "$REGION"
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION"
  aws ec2 create-tags --resources "$ALB_SG_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-alb-sg" Key=Project,Value="${TAG_PREFIX}"

  # ECS SG: 3000 인바운드 ALB_SG에서만 허용
  ECS_SG_ID=$(aws ec2 create-security-group \
      --group-name "${TAG_PREFIX}-ecs-sg" --description "ECS App SG" \
      --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
      --group-id "$ECS_SG_ID" --protocol tcp --port 3000 \
      --source-group "$ALB_SG_ID" --region "$REGION"
  aws ec2 create-tags --resources "$ECS_SG_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-ecs-sg" Key=Project,Value="${TAG_PREFIX}"

  # Redis SG: 6379 from ECS_SG only
  REDIS_SG_ID=$(aws ec2 create-security-group \
      --group-name "${TAG_PREFIX}-redis-sg" --description "Redis SG" \
      --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
      --group-id "$REDIS_SG_ID" --protocol tcp --port 6379 \
      --source-group "$ECS_SG_ID" --region "$REGION"
  aws ec2 create-tags --resources "$REDIS_SG_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-redis-sg" Key=Project,Value="${TAG_PREFIX}"

  # RDS SG: 5432 from ECS_SG only
  RDS_SG_ID=$(aws ec2 create-security-group \
      --group-name "${TAG_PREFIX}-rds-sg" --description "RDS SG" \
      --vpc-id "$VPC_ID" --region "$REGION" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
      --group-id "$RDS_SG_ID" --protocol tcp --port 5432 \
      --source-group "$ECS_SG_ID" --region "$REGION"
  aws ec2 create-tags --resources "$RDS_SG_ID" --region "$REGION" \
      --tags Key=Name,Value="${TAG_PREFIX}-rds-sg" Key=Project,Value="${TAG_PREFIX}"


  # 8) 저장(JSON)
  cat > "${OUTDIR}/network.json" <<JSON
{
  "Region": "${REGION}",
  "VpcId": "${VPC_ID}",
  "IgwId": "${IGW_ID}",
  "PublicSubnets": ["${PUB_SUBNET_IDS[0]}", "${PUB_SUBNET_IDS[1]:-}", "${PUB_SUBNET_IDS[2]:-}"],
  "PrivateSubnets": ["${PRI_SUBNET_IDS[0]}", "${PRI_SUBNET_IDS[1]:-}", "${PRI_SUBNET_IDS[2]:-}"],
  "NatGatewayIds": ["${NAT_IDS[0]}", "${NAT_IDS[1]:-}", "${NAT_IDS[2]:-}"],
  "RouteTablePublic": "${PUB_RT_ID}",
  "RouteTablesPrivate": ["${PRI_RT_IDS[0]}", "${PRI_RT_IDS[1]:-}", "${PRI_RT_IDS[2]:-}"],
  "AlbSecurityGroup": "${ALB_SG_ID}",
  "EcsSecurityGroup": "${ECS_SG_ID}",
  "RedisSecurityGroup": "${REDIS_SG_ID}",
  "RdsSecurityGroup": "${RDS_SG_ID}"
}
JSON

  echo "✔ ${REGION} network saved to infra/out/${REGION}/network.json"
done

# 9) 다음 단계에서 소싱할 env 파일 생성
GEN="${ROOT_DIR}/infra/out/.env.generated"
: > "$GEN"
for REGION in "${REGIONS[@]}"; do
  J="${ROOT_DIR}/infra/out/${REGION}/network.json"
  echo "# ${REGION}" >> "$GEN"
  echo "export VPC_ID_${REGION//-/_}=$(jq -r .VpcId "$J")" >> "$GEN"
  echo "export ALB_SG_${REGION//-/_}=$(jq -r .AlbSecurityGroup "$J")" >> "$GEN"
  echo "export ECS_SG_${REGION//-/_}=$(jq -r .EcsSecurityGroup "$J")" >> "$GEN"
  echo "export PUB_SUBNETS_${REGION//-/_}=$(jq -r '.PublicSubnets|join(",")' "$J")" >> "$GEN"
  echo "export PRI_SUBNETS_${REGION//-/_}=$(jq -r '.PrivateSubnets|join(",")' "$J")" >> "$GEN"
  echo "" >> "$GEN"
done
echo "✔ Generated env: infra/out/.env.generated"
