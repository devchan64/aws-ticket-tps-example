import Fastify from "fastify";
import helmet from "fastify-helmet";
import { cacheGetSetJSON } from "./cache/redis.js";
import { redis } from "./cache/redis.js";
import crypto from "node:crypto";

const app = Fastify({ logger: true });
await app.register(helmet);

app.get("/health", async () => ({ ok: true, ts: Date.now() }));
app.get("/public/ping", async () => ({ service: "public-api", ts: Date.now() }));

// 예시: 캐시가 먹히는 가벼운 읽기 엔드포인트
app.get("/public/summary/:event/:section", async (req) => {
  const { event, section } = req.params;
  const key = `sum:${event}:${section}`;
  return cacheGetSetJSON(key, 3, async () => {
    // TODO: 실제 원본 조회로 교체. 여기선 더미 데이터
    return {
      event, section,
      seatsAvailable: Math.floor(1000 * Math.random()),
      updatedAt: new Date().toISOString()
    };
  });
});

const port = Number(process.env.PORT || 3000);
app.listen({ port, host: "0.0.0.0" });
