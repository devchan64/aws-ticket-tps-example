FROM node:20-slim
WORKDIR /app

# pnpm 설치
RUN corepack enable && corepack prepare pnpm@9.6.0 --activate

# 루트 파일만 복사 후 의존성 설치(프루닝)
COPY package.json pnpm-workspace.yaml turbo.json ./
COPY packages/contracts/package.json packages/contracts/package.json
COPY apps/confirm-api/package.json apps/confirm-api/package.json

RUN pnpm install --frozen-lockfile --filter ./apps/confirm-api...

# 소스 복사
COPY packages ./packages
COPY apps/confirm-api ./apps/confirm-api

WORKDIR /app/apps/confirm-api
EXPOSE 3001
CMD ["node", "src/app.js"]
