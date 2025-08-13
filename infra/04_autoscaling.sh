#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"
source "${ROOT}/infra/out/.env.generated"

# Build ALB resource label: app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
alb_resource_label () {
  local REGION="$1"; local TG_ARN="$2"
  local TG=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --region "$REGION" --profile "$AWS_PROFILE")
  local LB_ARN=$(echo "$TG" | jq -r '.TargetGroups[0].LoadBalancerArns[0]')
  local LB=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" --region "$REGION" --profile "$AWS_PROFILE")
  local LB_PART=$(echo "$LB" | jq -r '.LoadBalancers[0].LoadBalancerArn' | sed -E 's#.*:loadbalancer/(.+)$#\1#')
  local TG_PART=$(echo "$TG" | jq -r '.TargetGroups[0].TargetGroupArn' | sed -E 's#.*:targetgroup/(.+)$#\1#')
  echo "${LB_PART}/${TG_PART}"
}

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] Application Auto Scaling ==="
  CLUSTER="ticket-${REGION}"

  # CPU TargetTracking (둘 다)
  for SVC in ticket-public-svc ticket-confirm-svc; do
    aws application-autoscaling register-scalable-target \
      --service-namespace ecs \
      --resource-id service/${CLUSTER}/${SVC} \
      --scalable-dimension ecs:service:DesiredCount \
      --min-capacity 12 --max-capacity 400 \
      --region "$REGION" --profile "$AWS_PROFILE"

    aws application-autoscaling put-scaling-policy \
      --service-namespace ecs \
      --resource-id service/${CLUSTER}/${SVC} \
      --scalable-dimension ecs:service:DesiredCount \
      --policy-name cpu60-tt \
      --policy-type TargetTrackingScaling \
      --target-tracking-scaling-policy-configuration '{
        "TargetValue": 60.0,
        "PredefinedMetricSpecification": {"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},
        "ScaleInCooldown": 60, "ScaleOutCooldown": 30
      }' \
      --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  done

  # ALB 기반 추가 정책 (public 전용 예시)
  OUT="${ROOT}/infra/out/${REGION}/alb.json"
  TG_PUBLIC=$(jq -r .TGPublic "$OUT")
  RESLABEL_PUBLIC=$(alb_resource_label "$REGION" "$TG_PUBLIC")

  # 타겟당 RPS (ALBRequestCountPerTarget)
  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/${CLUSTER}/ticket-public-svc \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name alb-rps-tt \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration "{
      \"TargetValue\": 800.0,
      \"PredefinedMetricSpecification\": {
        \"PredefinedMetricType\": \"ALBRequestCountPerTarget\",
        \"ResourceLabel\": \"${RESLABEL_PUBLIC}\"
      },
      \"ScaleInCooldown\": 60, \"ScaleOutCooldown\": 30
    }" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  # p95 지연 급등 시 StepScaling (TargetResponseTime > 0.2s)
  POL_ARN=$(aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/${CLUSTER}/ticket-public-svc \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name rtt-step \
    --policy-type StepScaling \
    --step-scaling-policy-configuration '{"AdjustmentType":"PercentChangeInCapacity","Cooldown":30,"MetricAggregationType":"Average","StepAdjustments":[{"MetricIntervalLowerBound":0,"ScalingAdjustment":20}]}' \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'PolicyARN' --output text)

  aws cloudwatch put-metric-alarm \
    --alarm-name ticket-${REGION}-public-rtt-high \
    --metric-name TargetResponseTime \
    --namespace AWS/ApplicationELB \
    --dimensions Name=LoadBalancer,Value="$(echo $RESLABEL_PUBLIC | cut -d/ -f1-3)" Name=TargetGroup,Value="$(echo $RESLABEL_PUBLIC | cut -d/ -f4-5)" \
    --statistic Average --period 60 --evaluation-periods 2 --threshold 0.2 --comparison-operator GreaterThanThreshold \
    --alarm-actions "$POL_ARN" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  # worker: SQS backlog 기반 TT + oldest age step
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id service/${CLUSTER}/ticket-worker-svc \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 6 --max-capacity 400 \
    --region "$REGION" --profile "$AWS_PROFILE"

  QNAME="ticket-confirm.fifo"
  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/${CLUSTER}/ticket-worker-svc \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name sqs-backlog-tt \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration "{
      \"TargetValue\": 1000,
      \"CustomizedMetricSpecification\": {
        \"Namespace\": \"AWS/SQS\",
        \"MetricName\": \"ApproximateNumberOfMessagesVisible\",
        \"Dimensions\": [{\"Name\":\"QueueName\",\"Value\":\"${QNAME}\"}],
        \"Statistic\": \"Average\"
      },
      \"ScaleInCooldown\": 60, \"ScaleOutCooldown\": 30
    }" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  POL2_ARN=$(aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/${CLUSTER}/ticket-worker-svc \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name sqs-oldest-step \
    --policy-type StepScaling \
    --step-scaling-policy-configuration '{"AdjustmentType":"PercentChangeInCapacity","Cooldown":30,"MetricAggregationType":"Average","StepAdjustments":[{"MetricIntervalLowerBound":0,"ScalingAdjustment":30}]}' \
    --region "$REGION" --profile "$AWS_PROFILE" --query 'PolicyARN' --output text)

  aws cloudwatch put-metric-alarm \
    --alarm-name ticket-${REGION}-sqs-oldest-high \
    --namespace AWS/SQS --metric-name ApproximateAgeOfOldestMessage \
    --dimensions Name=QueueName,Value=${QNAME} \
    --statistic Average --period 60 --evaluation-periods 1 --threshold 60 \
    --comparison-operator GreaterThanThreshold \
    --alarm-actions "$POL2_ARN" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null

  echo "✔ [$REGION] autoscaling policies applied."
done
