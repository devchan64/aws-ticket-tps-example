// apps/public-api/src/app.js
import Fastify from "fastify";
import helmet from "@fastify/helmet";
import swaggerUI from "@fastify/swagger-ui";
import openapiGlue from "@platformatic/fastify-openapi-glue";
import AWS from "aws-sdk";
import crypto from "node:crypto";

import { cacheGetSetJSON, redis } from "./cache/redis.js";
import { loadAndSliceSpec } from "../../../packages/spec-utils/slice.js";

const AWS_REGION = process.env.AWS_REGION || "ap-northeast-1";
AWS.config.update({ region: AWS_REGION });

const ROOM_TTL = parseInt(process.env.ROOM_TTL || "180", 10);
const HOLD_TTL = parseInt(process.env.HOLD_TTL || "120", 10);
const DDB_TABLE = process.env.DDB_TABLE || "ticket-seat-lock";
const ddb = new AWS.DynamoDB.DocumentClient({ region: AWS_REGION });

const app = Fastify({ logger: true });
await app.register(helmet);

const specPath = "openapi/ticketing.yaml";
// 단일 스펙에서 /public/*만 분리
const specPublic = loadAndSliceSpec(specPath, ["/public/"]);

await app.register(swaggerUI, {
  routePrefix: "/docs",
  uiConfig: { docExpansion: "list", deepLinking: true },
  specification: { document: specPublic }, // 파일 대신 “문서 객체” 주입
});

// 스펙의 operationId와 1:1 매핑되는 핸들러
class Service {
  // Redis 가용성 체크: 없으면 503
  ensureCacheOr503(reply) {
    if (!redis) {
      reply.code(503).send({
        error: "cache_unavailable",
        message: "Redis is not configured or unavailable",
      });
      return false;
    }
    return true;
  }

  async publicHealth() {
    return { ok: true, ts: Date.now() };
  }

  async pingPublic() {
    return { service: "public-api", ts: Date.now() };
  }

  async getSeatSummary(req) {
    const { event, section } = req.params;
    const key = `sum:${event}:${section}`;
    return cacheGetSetJSON(key, 3, async () => ({
      event,
      section,
      seatsAvailable: Math.floor(500 + Math.random() * 1000),
      updatedAt: new Date().toISOString(),
    }));
  }

  async enterWaitingRoom(req, reply) {
    const { userId, eventId } = req.body || {};
    if (!userId || !eventId)
      return reply.code(400).send({ error: "bad_request", message: "userId and eventId are required" });
    if (!this.ensureCacheOr503(reply)) return;

    const roomToken = crypto.randomBytes(16).toString("hex");
    await redis.setEx(
      `room:${roomToken}`,
      ROOM_TTL,
      JSON.stringify({ userId, eventId })
    );
    return { roomToken, position: 0, etaSec: 0 };
  }

  async getWaitingRoomStatus(req, reply) {
    if (!this.ensureCacheOr503(reply)) return;
    const { token } = req.query;
    const ttl = await redis.ttl(`room:${token}`);
    const exists = ttl !== -2;
    const left = Math.max(0, ttl > 0 ? ttl : 0);
    return { ready: !!exists, leftSec: left };
  }

  async holdSeat(req, reply) {
    if (!this.ensureCacheOr503(reply)) return;

    const token = req.headers["x-room-token"];
    if (!token) return reply.code(400).send({ error: "bad_request", message: "x-room-token header is required" });
    const alive = await redis.exists(`room:${token}`);
    if (!alive) return reply.code(401).send({ error: "room_expired", message: "waiting room expired" });

    const { eventId, seatId } = req.body || {};
    if (!eventId || !seatId)
      return reply.code(400).send({ error: "bad_request", message: "eventId and seatId are required" });

    const pk = `event#${eventId}`;
    const sk = `seat#${seatId}`;
    const ttl = Math.floor(Date.now() / 1000) + HOLD_TTL;

    try {
      await ddb
        .put({
          TableName: DDB_TABLE,
          Item: { pk, sk, ttl, status: "held" },
          ConditionExpression:
            "attribute_not_exists(pk) AND attribute_not_exists(sk)",
        })
        .promise();

      return {
        holdId: `${eventId}:${seatId}`,
        expiresAt: new Date(ttl * 1000).toISOString(),
      };
    } catch (e) {
      if (e?.code === "ConditionalCheckFailedException") {
        return reply.code(409).send({ error: "seat_already_held_or_sold", message: "seat is already held or sold" });
      }
      req.log.error(e);
      return reply.code(500).send({
        error: "ddb_error",
        message: "Failed to persist hold in DynamoDB",
      });
    }
  }

  async releaseSeat(req, reply) {
    if (!this.ensureCacheOr503(reply)) return;

    const { eventId, seatId } = req.body || {};
    const pk = `event#${eventId}`;
    const sk = `seat#${seatId}`;

    try {
      await ddb
        .delete({
          TableName: DDB_TABLE,
          Key: { pk, sk },
          ConditionExpression: "attribute_exists(pk) AND attribute_exists(sk)",
        })
        .promise();
      return { released: true };
    } catch (e) {
      req.log.warn({ err: e, pk, sk }, "release failed");
      return { released: false };
    }
  }

  async getEventSeats(req, reply) {
    const { eventId } = req.params;
    try {
      return {
        eventId,
        note:
          "demo - provide seat map via cache; held seats reflected by /hold TTL",
      };
    } catch (e) {
      req.log.error(e);
      return reply.code(500).send({ error: "seats_fetch_failed", message: "failed to fetch seats" });
    }
  }
}

// 스펙 기반 라우팅/검증 등록
await app.register(openapiGlue, {
  specification: specPublic,
  serviceHandlers: new Service(),
  prefix: "",
});

// (선택) 운영에서 Redis가 필수라면 Fail‑Fast
if (process.env.REDIS_REQUIRED === "true" && !redis) {
  app.log.error("[FATAL] Redis is required but not configured.");
  process.exit(1);
}

const port = Number(process.env.PORT || 3000);
app.listen({ port, host: "0.0.0.0" }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
