// apps/confirm-api/src/app.js
// ESM (package.json: { "type": "module" })
import Fastify from "fastify";
import helmet from "@fastify/helmet";
import swaggerUI from "@fastify/swagger-ui";
import openapiGlue from "@platformatic/fastify-openapi-glue";
import AWS from "aws-sdk";
import { Pool } from "pg";

import { loadAndSliceSpec } from "../../../packages/spec-utils/slice.js";
import { enqueueOne } from "./sqs.js";

const AWS_REGION = process.env.AWS_REGION || "ap-northeast-1";
AWS.config.update({ region: AWS_REGION });

const SQS_URL = process.env.SQS_URL || "";
const PG_URI = process.env.PG_URI || "";
const pg = PG_URI ? new Pool({ connectionString: PG_URI, max: 10 }) : null;
const UNIT_PRICE = parseInt(process.env.UNIT_PRICE || "10000", 10);

const app = Fastify({ logger: true });
await app.register(helmet);

const specPath = "openapi/ticketing.yaml";
const specConfirm = loadAndSliceSpec(specPath, ["/confirm/"]);

await app.register(swaggerUI, {
  routePrefix: "/docs",
  uiConfig: { docExpansion: "list", deepLinking: true },
  specification: { document: specConfirm },
});

class Service {
  // GET /confirm/health
  async confirmHealth() {
    return { ok: true, ts: Date.now() };
  }

  // POST /confirm/payment-intent
  async createPaymentIntent(req, reply) {
    const idem = req.headers["idempotency-key"];
    const { userId, eventId, seatIds = [] } = req.body || {};
    if (!idem || !userId || !eventId || !seatIds.length)
      return reply.code(400).send({ error: "bad_request" });

    const amount = seatIds.length * UNIT_PRICE;
    const intentId = "pi_" + Math.random().toString(36).slice(2);

    if (pg) {
      try {
        // 재시도(멱등) 확인
        const found = await pg.query(
          "SELECT intent_id, amount FROM payment_intents WHERE idempotency_key=$1 LIMIT 1",
          [idem]
        );
        if (found.rows[0]) {
          reply.header("X-Idempotent-Replay", "true");
          reply.header(
            "Location",
            `/confirm/status?idem=${encodeURIComponent(idem)}`
          );
          return reply.code(200).send({
            intentId: found.rows[0].intent_id,
            amount: found.rows[0].amount,
          });
        }

        // 최초 생성
        await pg.query(
          `INSERT INTO payment_intents (idempotency_key,intent_id,user_id,event_id,amount,created_at)
           VALUES ($1,$2,$3,$4,$5,NOW())`,
          [idem, intentId, userId, eventId, amount]
        );
      } catch (e) {
        req.log.error({ err: e }, "db_error on createPaymentIntent");
        return reply.code(500).send({ error: "db_error" });
      }
    }

    reply.header(
      "Location",
      `/confirm/status?idem=${encodeURIComponent(idem)}`
    );
    return reply.code(201).send({ intentId, amount });
  }

  // POST /confirm/commit
  async commitOrder(req, reply) {
    const idem = req.headers["idempotency-key"];
    const { intentId, eventId, seatIds = [], userId } = req.body || {};
    if (!idem || !intentId || !eventId || !seatIds.length || !userId)
      return reply.code(400).send({ error: "bad_request" });

    if (!SQS_URL) return reply.code(500).send({ error: "sqs_not_configured" });
    if (!SQS_URL.endsWith(".fifo")) {
      req.log.error({ SQS_URL }, "SQS URL is not FIFO");
      return reply.code(500).send({ error: "sqs_not_fifo" });
    }

    try {
      await enqueueOne(
        {
          type: "COMMIT_ORDER",
          payload: { intentId, eventId, seatIds, userId },
          idem,
        },
        idem, // groupKey: idem (멱등키 단위 순서 보장 or 샤딩 정책은 sqs.js 구현에 따름)
        idem // dedupBase: idem (5분 윈도 내 중복 차단)
      );
    } catch (e) {
      req.log.error({ err: e }, "sqs_send_error");
      return reply.code(503).send({ error: "temporarily_unavailable" });
    }

    reply.header(
      "Location",
      `/confirm/status?idem=${encodeURIComponent(idem)}`
    );
    return reply.code(202).send({ accepted: true, status: "PROCESSING", idem });
  }

  // GET /confirm/status
  async getStatus(req, reply) {
    const { idem } = req.query;
    if (!idem) return reply.code(400).send({ error: "bad_request" });
    if (!pg) return { order: null, payment: null };
    try {
      const o = await pg.query(
        "select id,idempotency_key,status,total,created_at from orders where idempotency_key=$1 limit 1",
        [idem]
      );
      const p = await pg.query(
        "select order_id,status,amount,approved_at,idempotency_key from payments where idempotency_key=$1 limit 1",
        [idem]
      );
      return { order: o.rows[0] || null, payment: p.rows[0] || null };
    } catch (e) {
      req.log.error({ err: e }, "db_error on getStatus");
      return reply.code(500).send({ error: "db_error" });
    }
  }
}

await app.register(openapiGlue, {
  specification: specConfirm,
  serviceHandlers: new Service(),
  prefix: "",
});

const port = Number(process.env.PORT || 3001);
app.listen({ port, host: "0.0.0.0" }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
