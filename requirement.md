# 프로젝트 요구사항 (`requirement.md`)

## 1. 프로젝트 개요

단일 AWS 계정에서 **최대 TPS**를 달성하기 위해 ECS Fargate, ALB, CloudFront, ElastiCache(Redis), Aurora PostgreSQL Serverless v2, SQS, DynamoDB를 활용한 고성능 API 플랫폼을 구축한다.  
테스트 목적은 10만 TPS 이상을 처리 가능한 구조를 설계·구현·검증하는 것이다.

---

## 2. 목표 성능

- **목표 TPS**: 100,000+ (외부 체감 기준)
- **지연 시간(p95)**: 200ms 이하 (핫패스)
- **가용성**: 99.9% 이상
- **확장성**: 무중단 확장, 자동 축소 지원

---

## 3. 아키텍처 구성

### 3.1 주요 컴포넌트

- **ECS Fargate (ap-northeast-1, ap-northeast-2)**
  - Public API 서비스 (`ticket-public`)
  - Confirm API 서비스 (`ticket-confirm`)
  - Confirm Worker 서비스 (`ticket-worker`)
- **네트워크**
  - VPC, Private/Public Subnet, NAT Gateway, Security Group
  - SG 정책: 최소 권한 원칙 (예: Redis 6379/ECS only, RDS 5432/ECS only)
- **로드 밸런싱 / CDN**
  - ALB (리전별)
  - CloudFront (Behavior 분리: `/public/*` 캐시 강화)
- **데이터 스토어**
  - DynamoDB: 좌석 잠금 테이블 (TTL 기반)
  - SQS (FIFO + DLQ): 주문 처리 비동기 큐
  - ElastiCache for Redis (Cluster Mode): 핫데이터 캐싱
  - Aurora PostgreSQL Serverless v2: 영속 저장소
- **CI/CD**
  - GitHub Actions: ECR 빌드/푸시 + ECS 서비스 강제 롤아웃

---

## 4. 오토스케일링 전략

- **Public / Confirm API**
  - CPU Utilization TargetTracking (60%)
  - ALBRequestCountPerTarget TargetTracking (예: 800 RPS/태스크)
  - TargetResponseTime 기반 StepScaling (p95 > 200ms 시 +20% 증설)
- **Worker**
  - SQS ApproximateNumberOfMessagesVisible TargetTracking
  - ApproximateAgeOfOldestMessage 기반 StepScaling

---

## 5. 성능 최적화 포인트

- **CloudFront 캐시**: `/public/*` 경로 TTL 10s, 브로틀리/압축 활성
- **Redis 캐시**: DB/DDB 조회 감소, TTL 1–3s 단기 캐싱, singleflight 적용
- **Aurora**: Serverless v2 ACU 튜닝, 커넥션 풀, 트랜잭션 최소화
- **DynamoDB**: PK/SK 설계 최적화, TTL 활용으로 쓰기부하 최소화

---

## 6. 테스트 및 검증

- **로드 테스트 도구**: PC/VM 기반 부하 생성기
- **부하 패턴**:
  - 70%: `/public` 조회
  - 20%: `/confirm` 요청
  - 10%: 백그라운드 처리(워커)
- **검증 항목**:
  - TPS, p95 지연 시간
  - AutoScaling 반응 속도
  - 장애 발생 시 복구 시간

---

## 7. 보안 및 관리

- IAM 역할 최소권한
- VPC 보안그룹 기반 네트워크 제한
- Secrets Manager를 통한 DB 자격증명 관리
- CloudWatch 지표/알람 설정

---

## 8. 배포/운영 프로세스

### 8.1 전제

- `env.sh`에 필수 변수 정의: `AWS_REGION`, `AWS_ACCOUNT_ID`, `APP_NAME`, `VPC_CIDR`, `AURORA_CLUSTER_ID`, `REDIS_CLUSTER_ID` 등.
- 각 스크립트는 **재실행 안전(idempotent)** 하게 작성하며, `.stamps/*.stamp` 존재 시 스킵.

### 8.2 실행 순서 (Make 타겟 매핑)

1. `make 00-network`

   - VPC, Subnet, Route, NAT, Security Group 생성

2. `make 01-ecr`

   - ECR 리포지토리 생성
   - 컨테이너 이미지 빌드 & 푸시 (`ticket-public`, `ticket-confirm`, `ticket-worker`)

3. `make 02-cluster`

   - ECS 클러스터, 서비스용 IAM Role, CloudWatch Log Group 생성

4. `make 03-dataplane`

   - SQS(FIFO+DLQ), DynamoDB(좌석잠금), (ElastiCache Redis), (Aurora Serverless v2) 생성/업데이트

5. `make 04-taskdefs`

   - 3개 서비스의 ECS Task Definition 등록/갱신

6. `make 05-services`

   - ALB, Target Group, Listener, ECS Service 생성/갱신

7. `make 06-autoscaling`

   - Application Auto Scaling 정책 적용
   - API: CPU 60% TargetTracking, ALB RPS/Target, p95 StepScaling
   - Worker: SQS 큐 길이/최고 메시지 연령 기반

8. `make 07-cloudfront`

   - CloudFront 배포(Behavior: `/public/*` 캐시 강화, Brotli/압축 on)

9. `make 08-db-init`
   - Aurora 스키마/시드 적용 (**재실행 안전**)

> 전체 자동 실행: `make all`

### 8.3 재실행/의존성

- 각 단계 완료 시 `.stamps/<step>.stamp` 생성 → 존재 시 스킵.
- 데이터플레인 의존성: `04-taskdefs`는 `03-dataplane` 이후, `05-services`는 `04-taskdefs` 이후.

### 8.4 롤아웃/롤백

- **롤아웃**: GitHub Actions → ECR 푸시 후 `aws ecs update-service --force-new-deployment`
- **빠른 롤백**: 이전 Task Definition 리비전으로 `update-service` 실행
- **안정화 확인**: ALB 5XX, TargetResponseTime, p95 지표 5분 안정 후 승격

### 8.5 스모크 테스트

- 헬스체크: `GET /public/health` 200
- 캐시 경로: `GET /public/*` 응답/헤더 확인 (CloudFront 캐시키, TTL)
- 결제 인텐트: `POST /confirm/payment-intent` (유효한 `idempotency-key`) 201/200 확인
- 워커 경로: SQS에 테스트 메시지 투입 → 소비/처리 로그 확인

### 8.6 관측/알림

- CloudWatch 대시보드: TPS, p95/p99, ECS Desired/Running, SQS 큐 길이, Redis HitRatio, Aurora 연결/IOPS
- 알람: ALB 5XX, TargetResponseTime, ECS CPU/Memory, SQS OldestMessageAge, Redis Eviction/CPU, Aurora ACU/스레들
- 트레이싱: X-Ray (핫패스), 구조적 로깅(JSON)

### 8.7 변경 관리

- IaC 변경은 PR 리뷰 후 머지 → GitHub Actions가 01~07 영향 범위 내 리소스만 변경
- 데이터 마이그레이션은 `08-db-init`에 포함하거나 전용 스텝으로 분리

---

## 9. 로드봇 시나리오

### 9.1 개요

- **목적**: 목표 TPS(100,000+) 및 p95 지연 시간(200ms 이하)을 실측 검증
- **환경**: AWS 외부 리전 또는 온프레미스 VM에서 부하 생성
- **도구**: k6 / Locust / custom Node.js 부하 스크립트
- **네트워크**: 전용 대역폭 확보(≥ 10Gbps), 지연 시간 측정 오차 최소화

---

### 9.2 시나리오 흐름

1. **사전 준비**

   - 테스트 계정 발급 (API Key/Token)
   - VU(virtual users) 수, ramp-up 시간, 목표 TPS 설정
   - CloudWatch 대시보드, X-Ray 트레이싱 활성화

2. **사전 워밍업**

   - `/public/health` 호출로 서비스 정상 여부 확인
   - 5분간 5,000 TPS 수준에서 워밍업 부하

3. **본 부하 테스트**

   - **부하 패턴 적용**
     - 70%: `/public` 조회 API 호출
     - 20%: `/confirm/payment-intent` 호출 (idempotency-key 포함)
     - 10%: SQS 메시지로 백그라운드 워커 트리거
   - 요청 파라미터 랜덤화(좌석 ID, 이벤트 ID 등)
   - Redis/DDB 캐시 적중률 변화 관측

4. **스텝 업 부하**

   - 10k TPS → 50k TPS → 100k TPS 단계별 증가 (각 5분 유지)
   - 단계별 p95 지연 시간과 에러율 측정
   - AutoScaling 정책 반응 확인 (ECS 태스크 수 변화)

5. **장시간 부하 유지**

   - 100k TPS 수준에서 30분간 지속 부하
   - Aurora, Redis, DDB 지표 수집 (CPU, IOPS, Throttle, Eviction 등)

6. **종료 및 쿨다운**
   - 10k TPS까지 점진적 감소
   - AutoScaling 축소 반응 속도 측정
   - 로그 및 메트릭 수집 완료

---

### 9.3 검증 항목

- 전체 TPS 및 목표 달성 여부
- p95, p99 지연 시간
- API별 성공률 (HTTP 2xx 비율)
- AutoScaling 반응 속도 (scale-out/in)
- 장애 발생 시 복구 시간
- Redis/DDB 캐시 적중률 변화
- Aurora 쿼리 지연 및 커넥션 수

---

### 9.4 종료 조건

- 목표 TPS 도달 후 10분 이상 유지 실패
- p95 지연 시간 200ms 초과 상태가 5분 이상 지속
- 에러율(HTTP 5xx) 2% 이상 지속
