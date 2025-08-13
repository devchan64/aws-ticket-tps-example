import Fastify from "fastify";
import helmet from "fastify-helmet";
import { sqs, QURL } from "./sqs.js";
import { randomUUID } from "crypto";

const app = Fastify({ logger: true });
await app.register(helmet);

app.get("/health", async () => ({ ok: true, ts: Date.now() }));

// 간단 검증 + SQS enqueue + 202
app.post("/confirm", async (req, reply) => {
  if (!QURL) return reply.code(500).send({ error: "SQS not configured" });

  const idem = req.headers["idempotency-key"] || randomUUID();
  const body = typeof req.body === "object" ? req.body : {};
  const { userId, eventId, seat } = body;
  if (!userId || !eventId || !seat) {
    return reply.code(400).send({ error: "userId,eventId,seat required" });
  }

  // FIFO 메시지: MessageGroupId = eventId, MessageDeduplicationId = idem
  const params = {
    QueueUrl: QURL,
    MessageBody: JSON.stringify({ userId, eventId, seat, idem, ts: Date.now() }),
    MessageGroupId: String(eventId),
    MessageDeduplicationId: String(idem)
  };

  try {
    await sqs.sendMessage(params).promise();
    return reply.code(202).send({ accepted: true, status: "PROCESSING", idem });
  } catch (e) {
    req.log.error(e, "sqs send failed");
    return reply.code(500).send({ error: "enqueue_failed" });
  }
});

const port = Number(process.env.PORT || 3000);
app.listen({ port, host: "0.0.0.0" });
