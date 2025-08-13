import AWS from "aws-sdk";
import { getClient } from "./db/pg.js";

const region = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION;
const sqs = new AWS.SQS({ region });
const QURL = process.env.SQS_URL;

const BATCH = parseInt(process.env.BATCH || "10", 10);
const WAIT = parseInt(process.env.WAIT || "10", 10);

// 최소 스키마(초기화 시 1회 호출)
async function ensureSchema(pg) {
  await pg.query(`
    CREATE TABLE IF NOT EXISTS orders (
      idempotency_key text PRIMARY KEY,
      user_id text NOT NULL,
      event_id text NOT NULL,
      seat text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_orders_event ON orders(event_id);
  `);
}

async function handleMessage(pg, msg) {
  const payload = JSON.parse(msg.Body);
  const { idem, userId, eventId, seat } = payload;

  // 아이템포턴시: PRIMARY KEY(idem)로 중복 방지
  await pg.query(
    `INSERT INTO orders (idempotency_key, user_id, event_id, seat)
     VALUES ($1,$2,$3,$4)
     ON CONFLICT (idempotency_key) DO NOTHING;`,
    [idem, userId, eventId, seat]
  );
}

async function loop() {
  if (!QURL) throw new Error("SQS_URL required");
  const pg = await getClient();
  await ensureSchema(pg);

  while (true) {
    const r = await sqs
      .receiveMessage({
        QueueUrl: QURL,
        MaxNumberOfMessages: BATCH,
        WaitTimeSeconds: WAIT,
        VisibilityTimeout: 30,
      })
      .promise();

    const msgs = r.Messages || [];
    if (msgs.length === 0) continue;

    const toDelete = [];
    for (const m of msgs) {
      try {
        await handleMessage(pg, m);
        toDelete.push({ Id: m.MessageId, ReceiptHandle: m.ReceiptHandle });
      } catch (e) {
        console.error("handle failed:", e);
      }
    }

    if (toDelete.length) {
      await sqs
        .deleteMessageBatch({
          QueueUrl: QURL,
          Entries: toDelete.map((h, i) => ({
            Id: String(i),
            ReceiptHandle: h.ReceiptHandle,
          })),
        })
        .promise();
    }
  }
}

loop().catch((e) => {
  console.error(e);
  process.exit(1);
});
