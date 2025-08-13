#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"
APP_PORT="${APP_PORT:-3000}"

# (선택) 리전별 ACM 인증서 ARN (없으면 443 리스너 생략하고 80에서 직접 포워드)
ACM_ARN_ap_northeast_1="${ACM_ARN_ap_northeast_1:-""}"
ACM_ARN_ap_northeast_2="${ACM_ARN_ap_northeast_2:-""}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] ALB & ECS services ==="
  OUTDIR="${ROOT}/infra/out/${REGION}"; mkdir -p "$OUTDIR"

  eval "PUB_SUBNETS=\$PUB_SUBNETS_${REGION//-/_}"
  eval "PRI_SUBNETS=\$PRI_SUBNETS_${REGION//-/_}"
  eval "ALB_SG=\$ALB_SG_${REGION//-/_}"
  eval "ECS_SG=\$ECS_SG_${REGION//-/_}"
  eval "VPC_ID=\$VPC_ID_${REGION//-/_}"

  IFS=',' read -r -a PUBS <<< "$PUB_SUBNETS"
  IFS=',' read -r -a PRIS <<< "$PRI_SUBNETS"

  # 1) ALB
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name ticket-alb-${REGION//-} \
    --subnets "${PUBS[@]}" \
    --security-groups "$ALB_SG" \
    --type application --ip-address-type ipv4 \
    --region "$REGION" --profile "$AWS_PROFILE" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  aws elbv2 add-tags --resource-arns "$ALB_ARN" \
    --tags Key=Project,Value=ticket --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  # 2) Target Groups
  TG_PUBLIC_ARN=$(aws elbv2 create-target-group --name ticket-tg-public --protocol HTTP --port ${APP_PORT} \
    --vpc-id "$VPC_ID" --target-type ip --region "$REGION" --profile "$AWS_PROFILE" \
    --health-check-protocol HTTP --health-check-path /health \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  TG_CONFIRM_ARN=$(aws elbv2 create-target-group --name ticket-tg-confirm --protocol HTTP --port ${APP_PORT} \
    --vpc-id "$VPC_ID" --target-type ip --region "$REGION" --profile "$AWS_PROFILE" \
    --health-check-protocol HTTP --health-check-path /health \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

  # 3) Listeners
  ACM_VAR="ACM_ARN_${REGION//-/_}"
  ACM_ARN="${!ACM_VAR:-}"

  L80_ARN=""
  L443_ARN=""

  if [[ -n "$ACM_ARN" ]]; then
    # 80은 443으로 리다이렉트
    L80_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
      --default-actions Type=redirect,RedirectConfig='{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}' \
      --region "$REGION" --profile "$AWS_PROFILE" --query 'Listeners[0].ListenerArn' --output text)

    # 443 리스너 및 규칙
    L443_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTPS --port 443 \
      --certificates CertificateArn="$ACM_ARN" \
      --default-actions Type=fixed-response,FixedResponseConfig='{"StatusCode":"404","ContentType":"text/plain","MessageBody":"notfound"}' \
      --region "$REGION" --profile "$AWS_PROFILE" --query 'Listeners[0].ListenerArn' --output text)

    aws elbv2 create-rule --listener-arn "$L443_ARN" --priority 10 \
      --conditions Field=path-pattern,Values='/public/*' \
      --actions Type=forward,TargetGroupArn="$TG_PUBLIC_ARN" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

    aws elbv2 create-rule --listener-arn "$L443_ARN" --priority 20 \
      --conditions Field=path-pattern,Values='/confirm' \
      --actions Type=forward,TargetGroupArn="$TG_CONFIRM_ARN" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  else
    # HTTPS 없음: 80에서 직접 포워드
    echo "⚠️  [$REGION] ACM ARN 미설정 → HTTPS 리스너 생략. HTTP(80)에서 포워드합니다."
    L80_ARN=$(aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
      --default-actions Type=fixed-response,FixedResponseConfig='{"StatusCode":"404","ContentType":"text/plain","MessageBody":"notfound"}' \
      --region "$REGION" --profile "$AWS_PROFILE" --query 'Listeners[0].ListenerArn' --output text)

    aws elbv2 create-rule --listener-arn "$L80_ARN" --priority 10 \
      --conditions Field=path-pattern,Values='/public/*' \
      --actions Type=forward,TargetGroupArn="$TG_PUBLIC_ARN" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

    aws elbv2 create-rule --listener-arn "$L80_ARN" --priority 20 \
      --conditions Field=path-pattern,Values='/confirm' \
      --actions Type=forward,TargetGroupArn="$TG_CONFIRM_ARN" \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  fi

  # 4) ECS Services
  CLUSTER="ticket-${REGION}"

  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name ticket-public-svc \
    --task-definition ticket-public \
    --desired-count 24 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${PRIS[*]}],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_PUBLIC_ARN},containerName=public,containerPort=${APP_PORT}" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name ticket-confirm-svc \
    --task-definition ticket-confirm \
    --desired-count 12 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${PRIS[*]}],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_CONFIRM_ARN},containerName=confirm,containerPort=${APP_PORT}" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name ticket-worker-svc \
    --task-definition ticket-worker \
    --desired-count 6 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${PRIS[*]}],securityGroups=[$ECS_SG],assignPublicIp=DISABLED}" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
        --region "$REGION" --profile "$AWS_PROFILE" --query 'LoadBalancers[0].DNSName' --output text)

  cat > "${OUTDIR}/alb.json" <<JSON
{"LoadBalancerArn":"${ALB_ARN}","DNSName":"${DNS}","TGPublic":"${TG_PUBLIC_ARN}","TGConfirm":"${TG_CONFIRM_ARN}",
 "Listener80":"${L80_ARN:-""}","Listener443":"${L443_ARN:-""}"}
JSON

  echo "✔ [$REGION] ALB ready: http(s)://${DNS}"
done
