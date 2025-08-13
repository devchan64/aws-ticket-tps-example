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

1. `make network` → VPC/SG/Subnet 생성
2. `make cluster` → ECS 클러스터 및 IAM 역할 생성
3. `make dataplane` → SQS, DDB, Redis, Aurora 생성
4. `make taskdefs` → Task Definition 등록
5. `make services` → 서비스 생성
6. `make autoscaling` → 오토스케일 정책 적용
7. GitHub Actions → 코드 변경 시 ECR 푸시 + 서비스 롤아웃

---
