/**
 * apps/confirm-api/src/app.js
 */
import Fastify from "fastify";
import helmet from "fastify-helmet";
import { enqueueOne } from "./sqs.js"; // ★ 전용 유틸 사용
import { randomUUID } from "crypto";

const app = Fastify({ logger: true });
await app.register(helmet);

app.get("/health", async () => ({ ok: true, ts: Date.now() }));

// 결제 intent 생성
app.post("/confirm/payment-intent", async (req, reply) => {
  const idem = req.headers["idempotency-key"];
  const { userId, eventId, seatIds = [] } = req.body || {};
  if (!idem || !userId || !eventId || !seatIds.length)
    return reply.code(400).send({ error: "bad_request" });

  const amount = seatIds.length * 10000;
  const intentId = "pi_" + Math.random().toString(36).slice(2);

  return { intentId, amount };
});

// 결제 승인 콜백
app.post("/confirm/payment-callback", async (req, reply) => {
  const { intentId, status, amount, txnId, eventId } = req.body || {};
  if (!intentId || !status)
    return reply.code(400).send({ error: "bad_request" });

  // 그룹 키: intentId 기준으로 샤딩 → 같은 intent 흐름은 같은 그룹에서 직렬 보장
  await enqueueOne(
    { type: "payment", intentId, status, amount, txnId, eventId },
    intentId,                            // ★ groupKey
    `pay:${intentId}`                    // ★ dedup base
  );

  return { ok: true };
});

// 커밋 요청
app.post("/confirm/commit", async (req, reply) => {
  const idem = req.headers["idempotency-key"];
  const { intentId, eventId, seatIds = [], userId } = req.body || {};
  if (!idem || !intentId || !eventId || !seatIds.length || !userId)
    return reply.code(400).send({ error: "bad_request" });

  // 그룹 키: idem(주문 단위 멱등 키) 기준 샤딩 → 같은 주문 커밋 흐름 직렬 보장
  await enqueueOne(
    { type: "commit", idem, intentId, eventId, seatIds, userId },
    idem,                                 // ★ groupKey
    `commit:${idem}`                       // ★ dedup base
  );

  return reply.code(202).send({ accepted: true, status: "PROCESSING", idem });
});

// 주문 상태 조회
import { Client } from "pg";
function pgClientFromEnv() {
  const secret = process.env.DB_SECRET_JSON
    ? JSON.parse(process.env.DB_SECRET_JSON)
    : {};
  return new Client({
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    user: secret.username,
    password: secret.password,
    // ssl: { rejectUnauthorized: false }
  });
}

app.get("/confirm/status", async (req, reply) => {
  const idem = req.query.idem;
  if (!idem) return reply.code(400).send({ error: "idem required" });
  const pg = pgClientFromEnv();
  try {
    await pg.connect();
    const o = await pg.query(
      "SELECT idempotency_key,status,total,created_at FROM orders WHERE idempotency_key=$1",
      [idem]
    );
    const p = await pg.query(
      "SELECT status,amount,approved_at FROM payments WHERE order_id=$1",
      [idem]
    );
    return {
      order: o.rows[0] || null,
      payment: p.rows[0] || null,
    };
  } catch (e) {
    req.log.error(e);
    return reply.code(500).send({ error: "db_error" });
  } finally {
    try { await pg.end(); } catch {}
  }
});

const port = Number(process.env.PORT || 3000);
app.listen({ port, host: "0.0.0.0" });
