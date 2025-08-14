# apps/public-api/Dockerfile
# 루트에서 -f 경로 지정
FROM node:20-alpine
WORKDIR /app

# pnpm 활성화
RUN corepack enable

# 워크스페이스 메타 + 잠금파일
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json ./

# 이 앱과 필요한 패키지만 최소 복사
COPY apps/public-api ./apps/public-api
COPY packages/spec-utils ./packages/spec-utils
# 🔹 OpenAPI 스펙을 앱 폴더로 복사 (app.js의 specPath: "openapi/ticketing.yaml"과 일치)
COPY openapi ./apps/public-api/openapi

# 프로덕션 의존성만 설치 (public-api 기준으로 좁혀 설치)
RUN pnpm install -r --filter ./apps/public-api... --prod --frozen-lockfile

# 런타임
WORKDIR /app/apps/public-api
ENV NODE_ENV=production PORT=3000
EXPOSE 3000
CMD ["node", "src/app.js"]
