# apps/confirm-api/Dockerfile
# 루트에서 -f 경로 지정
FROM node:20-slim
WORKDIR /app

# pnpm 설치
RUN corepack enable && corepack prepare pnpm@9.6.0 --activate

# package 파일과 lockfile 복사
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml turbo.json ./
COPY packages/contracts/package.json packages/contracts/package.json
COPY apps/confirm-api/package.json apps/confirm-api/package.json

# 의존성 설치
RUN pnpm install --frozen-lockfile --filter ./apps/confirm-api...

# 소스 복사
COPY packages ./packages
COPY apps/confirm-api ./apps/confirm-api
# ← openapi 스펙 복사 추가
COPY openapi ./openapi   

# 실행 설정
WORKDIR /app/apps/confirm-api
ENV NODE_ENV=production
EXPOSE 3001
CMD ["node", "src/app.js"]
