# max-tps-ecs (v0.1)

ECS Fargate로 최대 TPS 테스트를 위한 베이스 레포 (1차 커밋).

## 포함 내용

- 네트워크 인프라 풀 부트스트랩 (VPC/서브넷/IGW/NAT/라우팅/보안그룹) — 리전: ap-northeast-1, ap-northeast-2
- 최소 Node.js 앱 (public-api / confirm-api) + Dockerfile
- ECR 생성/푸시 스텁

## 빠른 시작

```bash
# 1) 환경변수 확인
vi env.sh

# 2) 네트워크 부트스트랩 (두 리전 자동)
make network

# 결과 확인
cat infra/out/ap-northeast-1/network.json
cat infra/out/ap-northeast-2/network.json
cat infra/out/.env.generated
```

## 다음 단계(차기 커밋 예정):

- ECS 클러스터/서비스/ALB 생성 스크립트
- 오토스케일 정책, SQS/DDB 등 데이터 평탄화 구성
- CloudFront + 캐시/보호 설정
