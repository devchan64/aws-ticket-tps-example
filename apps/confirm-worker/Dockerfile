FROM node:20-slim
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.6.0 --activate

COPY package.json pnpm-workspace.yaml turbo.json ./
COPY packages/contracts/package.json packages/contracts/package.json
COPY apps/confirm-worker/package.json apps/confirm-worker/package.json

RUN pnpm install --frozen-lockfile --filter ./apps/confirm-worker...

COPY packages ./packages
COPY apps/confirm-worker ./apps/confirm-worker

WORKDIR /app/apps/confirm-worker
CMD ["node", "src/worker.js"]
