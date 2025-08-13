import Fastify from "fastify";
import helmet from "fastify-helmet";
import crypto from "node:crypto";
import AWS from "aws-sdk";
import { cacheGetSetJSON, redis } from "./cache/redis.js";

const app = Fastify({ logger: true });
await app.register(helmet);

const ROOM_TTL = 180; // 3분
const HOLD_TTL = 120; // 2분
const DDB_TABLE = process.env.DDB_TABLE || "ticket_seat_lock";
const ddb = new AWS.DynamoDB.DocumentClient({
  region: process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION,
});

function tok() {
  return crypto.randomBytes(16).toString("hex");
}

// 헬스 체크
app.get("/health", async () => ({ ok: true, ts: Date.now() }));
app.get("/public/ping", async () => ({
  service: "public-api",
  ts: Date.now(),
}));

// 좌석 요약 조회(캐시)
app.get("/public/summary/:event/:section", async (req) => {
  const { event, section } = req.params;
  const key = `sum:${event}:${section}`;
  return cacheGetSetJSON(key, 3, async () => {
    return {
      event,
      section,
      seatsAvailable: Math.floor(1000 * Math.random()),
      updatedAt: new Date().toISOString(),
    };
  });
});

// 웨이팅룸 입장
app.post("/public/enter", async (req, reply) => {
  const { userId, eventId } = req.body || {};
  if (!userId || !eventId)
    return reply.code(400).send({ error: "userId,eventId required" });

  const roomToken = tok();
  if (redis)
    await redis.set(
      `room:${roomToken}`,
      JSON.stringify({ userId, eventId }),
      "EX",
      ROOM_TTL
    );
  return { roomToken, position: 0, etaSec: 0 };
});

// 웨이팅룸 상태 확인
app.get("/public/room-status", async (req, reply) => {
  const token = req.query.token;
  if (!token || !redis) return reply.send({ ready: true, leftSec: 0 });
  const v = await redis.ttl(`room:${token}`);
  return { ready: v > 0, leftSec: Math.max(v, 0) };
});

// 좌석 홀드
app.post("/public/hold", async (req, reply) => {
  const { eventId, seatId } = req.body || {};
  const roomToken = req.headers["x-room-token"];
  if (!roomToken || !eventId || !seatId)
    return reply.code(400).send({ error: "token,eventId,seatId required" });

  let ctx = null;
  if (redis) {
    const raw = await redis.get(`room:${roomToken}`);
    if (!raw) return reply.code(401).send({ error: "room_expired" });
    ctx = JSON.parse(raw);
  }

  const pk = `event#${eventId}`,
    sk = `seat#${seatId}`;
  const expires = Math.floor(Date.now() / 1000) + HOLD_TTL;

  try {
    await ddb
      .put({
        TableName: DDB_TABLE,
        Item: { pk, sk, user_id: ctx?.userId, expires_at: expires },
        ConditionExpression:
          "attribute_not_exists(pk) AND attribute_not_exists(sk)",
      })
      .promise();

    if (redis)
      await redis.set(
        `seat:hold:${eventId}:${seatId}`,
        JSON.stringify({ userId: ctx?.userId, until: expires }),
        "EX",
        HOLD_TTL
      );
    return {
      holdId: `${eventId}:${seatId}`,
      expiresAt: new Date(expires * 1000).toISOString(),
    };
  } catch {
    return reply.code(409).send({ error: "seat_already_held_or_sold" });
  }
});

// 좌석 해제
app.post("/public/release", async (req, reply) => {
  const { eventId, seatId } = req.body || {};
  const pk = `event#${eventId}`,
    sk = `seat#${seatId}`;
  await ddb.delete({ TableName: DDB_TABLE, Key: { pk, sk } }).promise();
  if (redis) await redis.del(`seat:hold:${eventId}:${seatId}`);
  return { released: true };
});

// 좌석 상태 조회(단순: DDB 홀드만 반영, sold는 2차 구현)
app.get("/public/seats/:eventId", async (req, reply) => {
  const { eventId } = req.params;
  // 이 구현은 데모 목적으로, 실제로는 Seats 테이블/캐시 스냅샷을 권장
  try {
    const heldPrefix = `event#${eventId}`;
    // DynamoDB는 prefix scan이 필요하므로 GSI가 없으면 PK exact만 가능.
    // 데모로는 "좌석 풀은 클라이언트가 가정"하고, 상태만 반환.
    return {
      eventId,
      note: "demo - provide seat map via cache; held seats reflected by /hold TTL",
    };
  } catch (e) {
    req.log.error(e);
    return reply.code(500).send({ error: "seats_fetch_failed" });
  }
});

const port = Number(process.env.PORT || 3000);
app.listen({ port, host: "0.0.0.0" });
