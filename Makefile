# Makefile
SHELL := /usr/bin/env bash
.PHONY: help all 00-network 01-ecr 02-cluster 03-dataplane 04-taskdefs 05-services 06-autoscaling 07-cloudfront 08-db-init clean-stamps

ROOT := $(shell pwd)
STAMPS := .stamps
ENV := $(ROOT)/env.sh

help:
	@echo "Execution order:"
	@echo "  00-network    -> VPC, Subnet, SG, Route, NAT"
	@echo "  01-ecr        -> ECR repos + build & push images"
	@echo "  02-cluster    -> ECS cluster, IAM roles, log groups"
	@echo "  03-dataplane  -> SQS, DynamoDB, (Redis), (Aurora)"
	@echo "  04-taskdefs   -> ECS Task Definitions (3 services)"
	@echo "  05-services   -> ALB, TG, Listeners, ECS Services"
	@echo "  06-autoscaling-> Application Auto Scaling policies"
	@echo "  07-cloudfront -> CloudFront distribution"
	@echo "  08-db-init    -> Apply DB schema to Aurora"
	@echo ""
	@echo "Run 'make all' to execute in order."

all: 00-network 01-ecr 02-cluster 03-dataplane 04-taskdefs 05-services 06-autoscaling 07-cloudfront 08-db-init

$(STAMPS):
	mkdir -p $(STAMPS)

00-network: | $(STAMPS)
	source $(ENV); bash infra/00_network_bootstrap.sh
	touch $(STAMPS)/00-network.stamp

01-ecr: 00-network | $(STAMPS)
	source $(ENV); bash infra/01_ecr_build_push.sh
	touch $(STAMPS)/01-ecr.stamp

02-cluster: 01-ecr | $(STAMPS)
	source $(ENV); bash infra/02_cluster_and_roles.sh
	touch $(STAMPS)/02-cluster.stamp

03-dataplane: 02-cluster | $(STAMPS)
	source $(ENV); bash infra/03_data_plane.sh
	touch $(STAMPS)/03-dataplane.stamp

04-taskdefs: 03-dataplane | $(STAMPS)
	source $(ENV); bash infra/04_task_defs.sh
	touch $(STAMPS)/04-taskdefs.stamp

05-services: 04-taskdefs | $(STAMPS)
	source $(ENV); bash infra/05_alb_services.sh
	touch $(STAMPS)/05-services.stamp

06-autoscaling: 05-services | $(STAMPS)
	source $(ENV); bash infra/06_autoscaling.sh
	touch $(STAMPS)/06-autoscaling.stamp

07-cloudfront: 06-autoscaling | $(STAMPS)
	source $(ENV); bash infra/07_cloudfront.sh
	touch $(STAMPS)/07-cloudfront.stamp

08-db-init: 03-dataplane | $(STAMPS)
	# Aurora 준비가 끝난 뒤 실행. 재실행 안전.
	source $(ENV); bash infra/08_db_init.sh
	touch $(STAMPS)/08-db-init.stamp

clean-stamps:
	rm -rf $(STAMPS)
