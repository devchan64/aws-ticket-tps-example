# aws-ticket-tps-example (max-tps-ecs)

ECS Fargate + ALB + CloudFront + Redis + SQS + DynamoDB + Aurora PostgreSQL Serverless v2로
단일 AWS 계정 · 2개 리전(ap-northeast-1, ap-northeast-2)에서 **고 TPS(100k+)**를 목표로 하는 예제입니다.

- 설계 목표: 외부 체감 100,000+ TPS, p95 ≤ 200ms(핫패스), 무중단 확장/축소
- 아키텍처 구성, 오토스케일링, 캐시/락 설계, E2E 시나리오로 검증
- `requirement.md` 참조

## 레포 구조

```
repo/
├─ apps/
│  ├─ public-api/        # /public/*  (Fastify + OpenAPI Glue)
│  ├─ confirm-api/       # /confirm/* (Fastify + OpenAPI Glue)
│  └─ confirm-worker/    # SQS FIFO consumer (Ajv validation)
├─ packages/
│  └─ spec-utils/        # ticketing.yaml 슬라이서(loadAndSliceSpec)
├─ openapi/
│  └─ ticketing.yaml     # 단일 스펙(공통) — /public/*, /confirm/* 모두 포함
├─ infra/                # 셸 스크립트 (VPC, ECS, ALB, SQS, DDB, Redis, Aurora, CloudFront)
├─ Makefile              # 배포/운영 순서 자동화
├─ turbo.json            # Turborepo 파이프라인
└─ pnpm-workspace.yaml   # 워크스페이스
```

## Quick Start

```bash
# 0) 네트워크
make 00-network       # VPC, Subnet, Route, NAT, SG

# 1) ECR + 이미지 빌드/푸시
make 01-ecr

# 2) 클러스터/IAM/로그
make 02-cluster

# 3) 데이터 평면
make 03-dataplane     # SQS(FIFO+DLQ), DDB(좌석잠금), (Redis), (Aurora)

# 4) 태스크 정의
make 04-taskdefs      # public-api, confirm-api, confirm-worker

# 5) 서비스/ALB
make 05-services      # ALB, TargetGroup, Listener, ECS Services

# 6) 오토스케일
make 06-autoscaling   # API: CPU, ALB RPS/Target, p95 StepScaling / Worker: SQS 지표

# 7) CloudFront(선택)
make 07-cloudfront    # /public/* 캐시 정책, Brotli/압축

# 8) DB 스키마 적용
make 08-db-init       # Aurora 스키마/시드 (재실행 안전)

# 전체 자동 실행
make all

```

> `infra/out/.env.generated` 와 리전별 `infra/out/<region>/*.json` 파일이 단계별로 생성/사용됩니다.

## 주요 서비스

- **public-api**: 웨이팅룸, 좌석 조회/홀드(캐시/TTL), `/public/*` 엔드포인트
- **confirm-api**: 결제 intent/승인 콜백/커밋 요청 → SQS enqueue
- **confirm-worker**: SQS consumer → Aurora 트랜잭션(아이템포턴시)

## 엔드포인트 개요

- `POST /public/enter` → `{ roomToken }`
- `GET  /public/room-status?token=...` → `{ ready, leftSec }`
- `POST /public/hold` (X-Room-Token 헤더) → `{ holdId, expiresAt }`
- `POST /public/release`
- `GET  /public/summary/:event/:section` (짧은 TTL 캐시)

- `POST /confirm/payment-intent` (Idempotency-Key)
- `POST /confirm/payment-callback` (PG 웹훅 시뮬레이터)
- `POST /confirm/commit` (Idempotency-Key)

## 환경 변수(서비스별)
- `env.sh`파일 참조

## 테스트/E2E

- `load/e2e/scenario_e2e.json` 의 `base.public`/`base.confirm`를 ALB 또는 CloudFront 도메인으로 설정
- `make e2e-run` 실행 후 `load/e2e/result.json`으로 요약 지표 확인

## 라이선스

MIT (레포 루트의 LICENSE 참조)
