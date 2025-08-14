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
      host, port, password,
      tls: tls ? {} : undefined,
      maxRetriesPerRequest: 2,
      enableAutoPipelining: true
    })
  : null;

// very small singleflight for hot keys
const inflight = new Map();
export async function cacheGetSetJSON(key, ttlSec, fetcher) {
  if (!redis) return fetcher();
  const cached = await redis.get(key);
  if (cached) return JSON.parse(cached);
  if (inflight.has(key)) return inflight.get(key);
  const p = (async () => {
    const data = await fetcher();
    await redis.set(key, JSON.stringify(data), "EX", ttlSec);
    inflight.delete(key);
    return data;
  })();
  inflight.set(key, p);
  return p;
}
