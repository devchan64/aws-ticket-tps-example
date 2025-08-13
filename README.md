# aws-ticket-tps-example (max-tps-ecs)

고TPS 구조(ECS Fargate + ALB + CloudFront + Redis + SQS + DynamoDB + Aurora PostgreSQL Serverless v2)를
단일 AWS 계정/두 리전(ap-northeast-1, ap-northeast-2)에서 구성하고, E2E 시나리오로 검증하는 예제입니다.

## Quick Start

```bash
# 0) 최초 네트워크/환경
make network

# 1) 클러스터/IAM
make cluster

# 2) 데이터 평면(SQS, DDB, Redis*, Aurora*)
make dataplane

# 3) 태스크 정의 등록
make taskdefs

# 4) ALB + ECS 서비스 생성
make services

# 5) 오토스케일 정책(CPU TT + ALB RPS TT + RTT StepScaling + SQS 기반)
make autoscaling

# 6) (선택) CloudFront 배포 + /public 캐시 정책
make cloudfront

# 7) DB 스키마 적용(Aurora)
make db-init

# 8) E2E 시나리오 실행(접속→홀드→결제→커밋)
make e2e-run
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

- **public-api**: `PORT`, `REDIS_HOST`, (`REDIS_PORT`, `REDIS_TLS`, `REDIS_AUTH_TOKEN`), `DDB_TABLE`
- **confirm-api**: `PORT`, `SQS_URL`
- **confirm-worker**: `SQS_URL`, `DB_HOST`, `DB_NAME`, `DB_SECRET_JSON`

## 테스트/E2E

- `load/e2e/scenario_e2e.json` 의 `base.public`/`base.confirm`를 ALB 또는 CloudFront 도메인으로 설정
- `make e2e-run` 실행 후 `load/e2e/result.json`으로 요약 지표 확인

## 라이선스

MIT (레포 루트의 LICENSE 참조)
