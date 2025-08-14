# aws-ticket-tps-example (max-tps-ecs)

ECS Fargate + ALB + CloudFront + Redis + SQS + DynamoDB + Aurora PostgreSQL Serverless v2로
단일 AWS 계정 · 2개 리전(ap-northeast-1, ap-northeast-2)에서 **고 TPS(100k+)**를 목표로 하는 예제입니다.

- 설계 목표: 외부 체감 100,000+ TPS, p95 ≤ 200ms(핫패스), 무중단 확장/축소
- 아키텍처 구성, 오토스케일링, 캐시/락 설계, E2E 시나리오로 검증
- `requirement.md` 참조

## 레포 구조

```
aws-ticket-tps-example/
├── .github/workflows/ # GitHub Actions CI/CD 워크플로우
│ └── cicd.yml
│
├── apps/ # 서비스 애플리케이션
│ ├── confirm-api/ # 결제 확인 API
│ │ ├── Dockerfile
│ │ ├── package.json
│ │ └── src/ # API 라우트 및 SQS 연동
│ ├── confirm-worker/ # 결제 처리 워커
│ │ ├── Dockerfile
│ │ ├── package.json
│ │ └── src/ # DB 연동 및 워커 로직
│ └── public-api/ # 공개 API 서비스
│   ├── Dockerfile
│   ├── package.json
│   └── src/ # API 라우트 및 Redis 캐시
│
├── infra/ # AWS 인프라 배포 스크립트
│ ├── 00_network_bootstrap.sh # 네트워크(VPC, 서브넷 등)
│ ├── 01_ecr_build_push.sh # ECR 빌드 및 푸시
│ ├── 02_cluster_and_roles.sh # ECS 클러스터/IAM 역할
│ ├── 03_data_plane.sh # SQS, DynamoDB, Redis, Aurora
│ ├── 04_task_defs.sh # ECS 태스크 정의
│ ├── 05_alb_services.sh # ALB 및 서비스 생성
│ ├── 06_autoscaling.sh # 오토스케일링 정책
│ ├── 07_cloudfront.sh # CloudFront 배포
│ └── 08_db_init.sh # DB 스키마 초기화
│
│ test/
│ ├─ e2e/                      # 계약/기능 중심 E2E 러너 (Playwright)
│ │  ├─ scripts/               # 실행 보조 유틸
│ │  ├─ helpers/               # 공통 검증/HTTP 유틸
│ │  ├─ fixtures/              # 테스트 데이터(유저/이벤트/좌석 등)
│ │  ├─ specs/                 # 스펙(스모크/계약/E2E 흐름)
│ │  └─ reports/               # Playwright HTML 리포트 출력
│ │
│ └─ loadtestbot/              # 최대 지속 TPS 산출(분산 부하 + 리포트)
│    ├─ scenarios/             # k6 시나리오
│    ├─ scripts/               # 분산 실행/수집/리포트
│    └─ reports/               # TPS 리포트(.md) 출력
│
├── openapi/ # API 계약 문서
│ └── ticketing.yaml
│
├── packages/ # 공유 패키지
│ ├── contracts/ # 서비스 간 계약 코드
│ └── spec-utils/ # 사양 유틸리티
│
├── tools/ # 개발/운영 도구
│ └── db/ # DB 초기화 스크립트
│
├── requirement.md # 프로젝트 요구사항
├── turbo.json # Turborepo 설정
├── pnpm-workspace.yaml # pnpm 모노레포 설정
├── package.json # 루트 패키지 설정
└── LICENSE # 라이선스
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

- **public-api**

  - `/public/*` 엔드포인트 제공
  - 웨이팅룸 입장(`enter`), 상태 조회(`room-status`)
  - 좌석 요약 조회(`summary/{event}/{section}`), 이벤트별 좌석 상태 조회(`seats/{eventId}`)
  - 좌석 홀드(`hold`) 및 해제(`release`) — 캐시/TTL 기반
  - 서비스 헬스체크(`/public/health`, `/public/ping`)

- **confirm-api**

  - `/confirm/*` 엔드포인트 제공
  - 결제 Intent 생성(`/payment-intent`), 승인 콜백, 커밋 요청(`/commit`)
  - 주문/결제 상태 조회(`/status`)
  - 모든 커밋 요청은 FIFO SQS로 비동기 처리
  - Idempotency-Key 기반 중복 방지 및 재실행 안전성 보장

- **confirm-worker**

  - SQS Consumer
  - 메시지 계약(`CommitSqsMessage`) 기반으로 Aurora DB 트랜잭션 수행
  - Commit 처리 시 아이템포턴시 보장

## 서비스 간 요청 흐름

```mermaid
sequenceDiagram
    autonumber
    participant U as User(Client)
    participant P as public-api
    participant C as confirm-api
    participant Q as SQS (FIFO)
    participant W as confirm-worker
    participant A as Aurora (DB)
    participant R as Redis/Cache

    Note over U,P: 1) 대기실 진입 및 좌석 조회
    U->>P: POST /public/enter {userId,eventId}
    P-->>U: {roomToken, position, etaSec}

    U->>P: GET /public/room-status?token=roomToken
    P-->>U: {ready,leftSec}

    U->>P: GET /public/summary/{event}/{section}
    P->>R: cache lookup
    alt cache hit
      R-->>P: summary
    else cache miss
      P-->>U: summary (and set TTL in Redis)
    end

    Note over U,P,C,Q,W,A: 2) 좌석 홀드 → Intent → 커밋(비동기)
    U->>P: POST /public/hold (x-room-token, {eventId,seatId})
    P->>R: hold with TTL
    R-->>P: {holdId,expiresAt}
    P-->>U: {holdId,expiresAt}

    U->>C: POST /confirm/payment-intent\n(Idempotency-Key, {userId,eventId,seatIds})
    C-->>U: 201 {intentId,amount}\n(or 200 X-Idempotent-Replay)

    U->>C: POST /confirm/commit\n(Idempotency-Key, {intentId,eventId,seatIds,userId})
    C->>Q: enqueue CommitSqsMessage(idem,payload)
    C-->>U: 202 Accepted + Location:/confirm/status?idem=...

    Note over Q,W,A: FIFO로 순서보장 처리, 아이템포턴시 보장
    Q-->>W: CommitSqsMessage
    W->>A: BEGIN; validate & write order/payment; COMMIT
    W-->>Q: delete message on success

    Note over U,C,A: 3) 상태 폴링
    U->>C: GET /confirm/status?idem=...
    C->>A: query by idem
    A-->>C: {order,payment}
    C-->>U: {order,payment}

    Note over P,R: 만료/해제
    U->>P: POST /public/release {eventId,seatId}
    P->>R: release hold
    R-->>P: {released:true}
```

## 환경 변수(서비스별)

- `env.sh`파일 참조

## 테스트/E2E

- `load/e2e/scenario_e2e.json` 의 `base.public`/`base.confirm`를 ALB 또는 CloudFront 도메인으로 설정
- `make e2e-run` 실행 후 `load/e2e/result.json`으로 요약 지표 확인

### env.sh → test/.env 동기화 스크립트

```bash
tools/sync-dotenv.sh
```

### 절차 요약

```bash
# 1) env.sh 로드 및 .env 동기화
tools/sync-dotenv.sh

# 2) e2e
cd test/e2e
npm i && npx playwright install --with-deps
npm run pretest && npm run test:smoke

# 3) loadtestbot
cd ../loadtestbot
npm i
npm run ecs:run            # 또는 위 '지역별 워커 수에 맞춘 실행' 예시
node scripts/collect-cloudwatch.js > /tmp/k6.json
npm run report -- /tmp/k6.json
```

## 라이선스

MIT (레포 루트의 LICENSE 참조)
