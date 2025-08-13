#!/usr/bin/env bash
set -euo pipefail

# 네트워크: VPC, 퍼블릭/프라이빗 서브넷, IGW, NAT, 라우팅, SG 생성
# 결과는 infra/out/<region>/network.json 및 infra/out/.env.generated 에 반영

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

OUT_ALL="${ROOT}/infra/out"
mkdir -p "${OUT_ALL}"

ENV_OUT="${OUT_ALL}/.env.generated"
: > "${ENV_OUT}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] network bootstrap ==="
  OUTDIR="${OUT_ALL}/${REGION}"; mkdir -p "${OUTDIR}"

  VPC_CIDR_VAR="VPC_CIDR_${REGION//-/_}"
  VPC_CIDR="${!VPC_CIDR_VAR:-10.10.0.0/16}"

  # 1) VPC
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --region "$REGION" --profile "$AWS_PROFILE" \
    --query 'Vpc.VpcId' --output text)
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="ticket-${REGION}-vpc" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  # 2) Subnets (고정 CIDR 또는 기본 값)
  # 퍼블릭
  PUB_CIDRS_VAR="PUB_CIDRS_${REGION//-/_}"
  PRI_CIDRS_VAR="PRI_CIDRS_${REGION//-/_}"
  IFS=',' read -r -a PUBS_CIDR <<< "${!PUB_CIDRS_VAR:-10.10.0.0/20,10.10.16.0/20,10.10.32.0/20}"
  IFS=',' read -r -a PRIS_CIDR <<< "${!PRI_CIDRS_VAR:-10.10.64.0/20,10.10.80.0/20,10.10.96.0/20}"

  AZS=($(aws ec2 describe-availability-zones --region "$REGION" --profile "$AWS_PROFILE" --query 'AvailabilityZones[].ZoneName' --output text))
  SUBNETS_PUB=()
  SUBNETS_PRI=()

  for i in "${!PUBS_CIDR[@]}"; do
    AZ="${AZS[$i]}"
    S=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "${PUBS_CIDR[$i]}" --availability-zone "$AZ" \
      --region "$REGION" --profile "$AWS_PROFILE" --query 'Subnet.SubnetId' --output text)
    aws ec2 modify-subnet-attribute --subnet-id "$S" --map-public-ip-on-launch \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
    SUBNETS_PUB+=("$S")
  done

  for i in "${!PRIS_CIDR[@]}"; do
    AZ="${AZS[$i]}"
    S=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "${PRIS_CIDR[$i]}" --availability-zone "$AZ" \
      --region "$REGION" --profile "$AWS_PROFILE" --query 'Subnet.SubnetId' --output text)
    SUBNETS_PRI+=("$S")
  done

  # 3) IGW, NAT, RT
  IGW=$(aws ec2 create-internet-gateway --region "$REGION" --profile "$AWS_PROFILE" --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --profile "$AWS_PROFILE" --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  for s in "${SUBNETS_PUB[@]}"; do
    aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$s" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  done

  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$REGION" --profile "$AWS_PROFILE" --query 'AllocationId' --output text)
  NATGW=$(aws ec2 create-nat-gateway --subnet-id "${SUBNETS_PUB[0]}" --allocation-id "$EIP_ALLOC" \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 wait nat-gateway-available --nat-gateway-ids "$NATGW" --region "$REGION" --profile "$AWS_PROFILE"

  RT_PRI=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$REGION" --profile "$AWS_PROFILE" --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id "$RT_PRI" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NATGW" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  for s in "${SUBNETS_PRI[@]}"; do
    aws ec2 associate-route-table --route-table-id "$RT_PRI" --subnet-id "$s" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  done

  # 4) SG
  ALB_SG=$(aws ec2 create-security-group --group-name "ticket-alb-sg" --description "alb sg" --vpc-id "$VPC_ID" \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'GroupId' --output text)
  ECS_SG=$(aws ec2 create-security-group --group-name "ticket-ecs-sg" --description "ecs sg" --vpc-id "$VPC_ID" \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80  --cidr 0.0.0.0/0 \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null || true
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 443 --cidr 0.0.0.0/0 \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null || true

  # ECS SG는 ALB에서만 접근
  aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 3000 --source-group "$ALB_SG" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null || true

  # 5) 출력
  PUB_JOIN=$(IFS=, ; echo "${SUBNETS_PUB[*]}")
  PRI_JOIN=$(IFS=, ; echo "${SUBNETS_PRI[*]}")

  cat > "${OUTDIR}/network.json" <<JSON
{"VpcId":"${VPC_ID}","PublicSubnets":"${PUB_JOIN}","PrivateSubnets":"${PRI_JOIN}",
 "AlbSg":"${ALB_SG}","EcsSg":"${ECS_SG}"}
JSON

  echo "export VPC_ID_${REGION//-/_}=${VPC_ID}" >> "${ENV_OUT}"
  echo "export PUB_SUBNETS_${REGION//-/_}=${PUB_JOIN}" >> "${ENV_OUT}"
  echo "export PRI_SUBNETS_${REGION//-/_}=${PRI_JOIN}" >> "${ENV_OUT}"
  echo "export ALB_SG_${REGION//-/_}=${ALB_SG}" >> "${ENV_OUT}"
  echo "export ECS_SG_${REGION//-/_}=${ECS_SG}" >> "${ENV_OUT}"

  echo "✔ [$REGION] network ready"
done

echo "export NETWORK_READY=1" >> "${ENV_OUT}"
