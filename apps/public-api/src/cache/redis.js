/**
 * apps/public-api/src/cache/redis.js
 */
import Redis from "ioredis";

const host = process.env.REDIS_HOST;
const tls = process.env.REDIS_TLS === "true";
const port = Number(process.env.REDIS_PORT || 6379);
const password = process.env.REDIS_AUTH_TOKEN;

export const redis = host
  ? new Redis({
      host,
      port,
      password,
      tls: tls ? {} : undefined,
      maxRetriesPerRequest: 2,
      enableAutoPipelining: true,
    })
  : null;

// very small singleflight for hot keys
const inflight = new Map();

/**
 * JSON 캐시 헬퍼 (singleflight)
 * - Redis 미구성 시: 패스스루
 * - 손상된 캐시(JSON.parse 예외): 무시하고 재계산
 * - fetcher/redis.set 실패 시에도 inflight 누수 없이 정리
 * - ttlSec 최소 1초 보장
 */
export async function cacheGetSetJSON(key, ttlSec, fetcher) {
  if (!redis) return fetcher();

  // 1) 캐시 조회 (손상 방지)
  const cached = await redis.get(key);
  if (cached) {
    try {
      return JSON.parse(cached);
    } catch {
      // 손상된 캐시는 무시하고 재계산
    }
  }

  // 2) 단일 비행
  if (inflight.has(key)) return inflight.get(key);

  // TTL 가드
  const ttl = Number.isFinite(ttlSec) && ttlSec > 0 ? Math.floor(ttlSec) : 1;

  const p = (async () => {
    try {
      const data = await fetcher();
      await redis.set(key, JSON.stringify(data), "EX", ttl);
      return data;
    } finally {
      inflight.delete(key);
    }
  })();

  inflight.set(key, p);
  return p;
}
