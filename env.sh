#!/usr/bin/env bash
set -euo pipefail

# ===== Project-wide =====
export TAG_PREFIX="ticket"                           
export AWS_PROFILE="default"                         
export REGIONS=("ap-northeast-1" "ap-northeast-2")  

# ===== VPC CIDR (리전별) =====
# 서로 겹치지 않게 설정
export VPC_CIDR_ap_northeast_1="10.11.0.0/16"
export VPC_CIDR_ap_northeast_2="10.12.0.0/16"

# /20씩 3개 퍼블릭, 3개 프라이빗 (AZ 3개 기준)
# 필요 시 바꾸세요.
export PUB_BLOCKS="/20,/20,/20"
export PRI_BLOCKS="/20,/20,/20"

# ===== ECR Repos (다음 단계에서 사용) =====
export ECR_PUBLIC_REPO="public-api"
export ECR_CONFIRM_REPO="confirm-api"

# 결과 저장용 S3 버킷 (리전에 따라 자동 접미사)
export LOAD_S3_BUCKET_PREFIX="ticket-load-results"

# 부하 기본 파라미터(워커 공통)
export LOAD_DURATION_SEC=60             # 각 워커 실행 시간
export LOAD_TARGET_RPS_PER_WORKER=4000  # 워커 한 대당 목표 RPS
export LOAD_CONCURRENCY=600             # 동시성(소켓/요청 in-flight 상한)

# 워커 대수(리전별)
export LOAD_WORKERS_ap_northeast_1=10
export LOAD_WORKERS_ap_northeast_2=10

# ==== Redis (옵션) ====
export ENABLE_REDIS=${ENABLE_REDIS:-true}
export REDIS_NODE_GROUPS=${REDIS_NODE_GROUPS:-3}        # shard 수(Cluster Mode)
export REDIS_REPLICAS_PER_GROUP=${REDIS_REPLICAS_PER_GROUP:-1}
export REDIS_NODE_TYPE=${REDIS_NODE_TYPE:-cache.r7g.large}

# ==== RDS / Aurora PostgreSQL Serverless v2 ====
export ENABLE_AURORA=${ENABLE_AURORA:-true}
export AURORA_ENGINE_VERSION=${AURORA_ENGINE_VERSION:-15.4}
export AURORA_DB_NAME=${AURORA_DB_NAME:-ticketdb}
export AURORA_ADMIN_USER=${AURORA_ADMIN_USER:-ticketadmin}
export AURORA_MIN_ACU=${AURORA_MIN_ACU:-2}              # 2~384 ACU
export AURORA_MAX_ACU=${AURORA_MAX_ACU:-64}
