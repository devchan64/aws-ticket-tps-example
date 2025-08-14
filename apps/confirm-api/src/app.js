// apps/confirm-api/src/app.js
import Fastify from "fastify";
import helmet from "@fastify/helmet";
import swaggerUI from "@fastify/swagger-ui";
import openapiGlue from "@platformatic/fastify-openapi-glue";
import path from "node:path";
import AWS from "aws-sdk";
import { Pool } from "pg";

import { loadAndSliceSpec } from "../../../packages/spec-utils/slice.js";

const AWS_REGION = process.env.AWS_REGION || "ap-northeast-1";
AWS.config.update({ region: AWS_REGION });
const QURL = process.env.QURL || "";
const sqs = new AWS.SQS({ apiVersion: "2012-11-05" });
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
    // (옵션) DB 기록
    if (pg)
      await pg
        .query(
          `INSERT INTO payment_intents (idempotency_key,intent_id,user_id,event_id,amount,created_at)
       VALUES ($1,$2,$3,$4,$5,NOW()) ON CONFLICT (idempotency_key) DO NOTHING`,
          [idem, intentId, userId, eventId, amount]
        )
        .catch(() => {});
    // 최초 생성이면 201로 내려주고, 재시도면 200으로도 가능(스펙에 둘 다 정의해둠)
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
    if (!QURL) return reply.code(500).send({ error: "sqs_not_configured" });

    await sqs
      .sendMessage({
        QueueUrl: QURL,
        MessageGroupId: idem,
        MessageDeduplicationId: idem,
        MessageBody: JSON.stringify({
          type: "COMMIT_ORDER",
          payload: { intentId, eventId, seatIds, userId },
          idem,
        }),
      })
      .promise();

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
    const o = await pg.query(
      "select id,idempotency_key,status,total,created_at from orders where idempotency_key=$1 limit 1",
      [idem]
    );
    const p = await pg.query(
      "select order_id,status,amount,approved_at,idempotency_key from payments where idempotency_key=$1 limit 1",
      [idem]
    );
    return { order: o.rows[0] || null, payment: p.rows[0] || null };
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
