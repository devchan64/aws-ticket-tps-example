#!/usr/bin/env bash
set -euo pipefail

# ECR 리포지토리 생성 + 이미지 빌드/푸시 (public, confirm, worker)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/env.sh"

ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --profile $AWS_PROFILE)}"

create_repo () {
  local REGION="$1"; local NAME="$2"
  aws ecr describe-repositories --repository-names "$NAME" \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$NAME" \
    --image-scanning-configuration scanOnPush=true \
    --region "$REGION" --profile "$AWS_PROFILE" >/dev/null
}

for REGION in "${REGIONS[@]}"; do
  echo "=== [$REGION] ECR build & push ==="

  aws ecr get-login-password --region "$REGION" --profile "$AWS_PROFILE" \
    | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

  # repos
  create_repo "$REGION" "${ECR_PUBLIC_REPO}"
  create_repo "$REGION" "${ECR_CONFIRM_REPO}"
  create_repo "$REGION" "${ECR_WORKER_REPO:-confirm-worker}"

  # public
  docker build -t ${ECR_PUBLIC_REPO}:prod "${ROOT}/apps/public-api"
  docker tag  ${ECR_PUBLIC_REPO}:prod ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PUBLIC_REPO}:prod
  docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PUBLIC_REPO}:prod

  # confirm
  docker build -t ${ECR_CONFIRM_REPO}:prod "${ROOT}/apps/confirm-api"
  docker tag  ${ECR_CONFIRM_REPO}:prod ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_CONFIRM_REPO}:prod
  docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_CONFIRM_REPO}:prod

  # worker
  WORKER_REPO="${ECR_WORKER_REPO:-confirm-worker}"
  docker build -t ${WORKER_REPO}:prod "${ROOT}/apps/confirm-worker"
  docker tag  ${WORKER_REPO}:prod ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${WORKER_REPO}:prod
  docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${WORKER_REPO}:prod

  echo "✔ [$REGION] ECR pushed"
done
