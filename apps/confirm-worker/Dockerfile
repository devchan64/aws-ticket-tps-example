# apps/confirm-worker/Dockerfile
FROM node:20-slim AS base
WORKDIR /app
ENV NODE_ENV=production
RUN corepack enable && corepack prepare pnpm@9.6.0 --activate

# 워크스페이스 메타 / 패키지 매니페스트
COPY package.json pnpm-workspace.yaml turbo.json ./
COPY packages/contracts/package.json packages/contracts/package.json
COPY apps/confirm-worker/package.json apps/confirm-worker/package.json

# 프로덕션 의존성만 설치 (confirm-worker 워크스페이스 한정)
RUN pnpm install --frozen-lockfile --prod --filter ./apps/confirm-worker...

# 실제 소스 복사
COPY packages ./packages
COPY apps/confirm-worker ./apps/confirm-worker
# ✅ OpenAPI 스펙 복사 (worker가 참조)
COPY openapi ./openapi

WORKDIR /app/apps/confirm-worker
CMD ["node", "src/worker.js"]
