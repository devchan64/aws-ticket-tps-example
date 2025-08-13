#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/env.sh"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile ${AWS_PROFILE})}"

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] ECR login/create/push ==="
  aws ecr get-login-password --region "$REGION" --profile "$AWS_PROFILE" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

  for REPO in "${ECR_PUBLIC_REPO}" "${ECR_CONFIRM_REPO}" "${ECR_WORKER_REPO:-confirm-worker}"; do
    aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$REPO" --image-tag-mutability IMMUTABLE \
         --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
  done

  # build & push public
  docker build -t ${ECR_PUBLIC_REPO}:prod "${ROOT_DIR}/apps/public-api"
  docker tag ${ECR_PUBLIC_REPO}:prod ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PUBLIC_REPO}:prod
  docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PUBLIC_REPO}:prod

  # build & push confirm
  docker build -t ${ECR_CONFIRM_REPO}:prod "${ROOT_DIR}/apps/confirm-api"
  docker tag ${ECR_CONFIRM_REPO}:prod ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/_
