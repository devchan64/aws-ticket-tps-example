SHELL := /usr/bin/env bash
.DEFAULT_GOAL := all

ENV_FILE := infra/out/.env.generated

.PHONY: all help \
        network cluster taskdefs alb services autoscaling dataplane cloudfront \
        load-start load-report \
        _need_env

help:
	@echo "Usage:"
	@echo "  make all            # network -> cluster -> taskdefs -> services -> autoscaling -> dataplane -> cloudfront"
	@echo "  make network        # VPC/Subnets/NAT/SG bootstrap"
	@echo "  make cluster        # ECS cluster, roles, log groups"
	@echo "  make taskdefs       # Register task definitions"
	@echo "  make alb            # Create ALB, TGs, listeners"
	@echo "  make services       # Create ECS services (depends on 'alb')"
	@echo "  make autoscaling    # Apply Application Auto Scaling policies"
	@echo "  make dataplane      # Create SQS/DynamoDB, etc."
	@echo "  make cloudfront     # Create CloudFront distribution"
	@echo "  make load-start     # Launch EC2 load workers"
	@echo "  make load-report    # Collect results and write report"

# ---- Orchestration ----
all: network cluster taskdefs services autoscaling dataplane cloudfront

# ---- Steps ----
network:
	./infra/00_network_bootstrap.sh

cluster: _need_env
	source $(ENV_FILE) && ./infra/02_cluster_and_roles.sh

taskdefs: _need_env
	source $(ENV_FILE) && ./infra/02_task_defs.sh

alb: _need_env
	source $(ENV_FILE) && ./infra/03_alb_services.sh

# Ensure ALB exists before creating services
services: alb

autoscaling: _need_env
	source $(ENV_FILE) && ./infra/04_autoscaling.sh

dataplane: _need_env
	source $(ENV_FILE) && ./infra/05_data_plane.sh

cloudfront: _need_env
	source $(ENV_FILE) && ./infra/06_cloudfront.sh

# ---- Load test ----
load-start:
	./load/10_launch_workers.sh

load-report:
	./load/20_collect_and_report.sh

# 예: ECR 빌드/푸시 스텁 확장
ecr:
	./infra/01_ecr_build_push.sh  # 내부에서 confirm-worker까지 빌드/푸시하도록 확장


# ---- Guards ----
_need_env:
	@test -f $(ENV_FILE) || (echo "❌ $(ENV_FILE) not found. Run 'make network' first to generate it." && exit 1)
