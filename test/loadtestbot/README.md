# 사용 순서

## 환경 준비

```bash
cp .env.example .env
# 필요한 값 채움 (ECS, REGIONS, 네트워크, 로그그룹 등)
```

## ALB 확인 및 헬스

```bash
npm run pretest
```

## 로컬 부하(연기 테스트)

```bash
npm run local:ping
# 또는
npm run local:reserve
```

## ECS 분산 실행 (기본 ping.k6.js)

```bash
npm run ecs:run
# 환경변수로 RATE/DURATION 조절 가능, 시나리오 파일명을 인자로 줄 수도 있음:
# node scripts/orchestrate-ecs.js scenarios/reserve-flow.k6.js

##결과 수집 → 리포트
```

```bash
# 최근 30분 로그에서 요약 수집
node scripts/collect-cloudwatch.js > /tmp/k6-summaries.json

# 리포트 생성
npm run report -- /tmp/k6-summaries.json
# 결과: test/loadtestbot/reports/tps-report-YYYY-MM-DDTHH-MM-SSZ.md
```
