// ESM
import AWS from "aws-sdk";
import { getClient } from "./db/pg.js";

const REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "ap-northeast-1";
const QURL = process.env.SQS_URL;
const DDB_TABLE = process.env.DDB_TABLE || "ticket-seat-lock"; // ← 인프라의 테이블명과 일치(하이픈)
const BATCH = Math.min(parseInt(process.env.BATCH || "10", 10), 10);
const WAIT = parseInt(process.env.WAIT || "10", 10); // (미사용 시 0~10초 지연 전략에 활용 가능)
const LONG_POLL = parseInt(process.env.SQS_LONG_POLL || "20", 10);
const VISIBILITY = parseInt(process.env.SQS_VISIBILITY || "120", 10);

if (!QURL) {
  throw new Error("[worker] SQS_URL is not set");
}

AWS.config.update({ region: REGION });
const sqs = new AWS.SQS({ apiVersion: "2012-11-05", region: REGION });
const ddb = new AWS.DynamoDB.DocumentClient({ region: REGION });

async function commitOrder(pg, msg) {
  const { idem, intentId, userId, eventId, seatIds } = msg;

  // 1) 좌석 잠금 재검증 (존재/유효성)
  for (const seatId of seatIds) {
    const g = await ddb
      .get({
        TableName: DDB_TABLE,
        Key: { pk: `event#${eventId}`, sk: `seat#${seatId}` },
      })
      .promise();
    if (!g.Item) throw new Error(`lock-missing ${seatId}`);
  }

  // 2) 트랜잭션: orders upsert + order_items upsert + DDB lock 삭제
  await pg.query("BEGIN");
  try {
    await pg.query(
      `
      INSERT INTO orders (idempotency_key, user_id, event_id, status, total)
      VALUES ($1,$2,$3,'CONFIRMED',0)
      ON CONFLICT (idempotency_key) DO NOTHING;
    `,
      [idem, userId, eventId]
    );

    for (const seatId of seatIds) {
      await pg.query(
        `
        INSERT INTO order_items(order_id, seat_id, price)
        SELECT o.idempotency_key, $2, 10000 FROM orders o WHERE o.idempotency_key=$1
        ON CONFLICT DO NOTHING;
      `,
        [idem, seatId]
      );
      await ddb
        .delete({
          TableName: DDB_TABLE,
          Key: { pk: `event#${eventId}`, sk: `seat#${seatId}` },
        })
        .promise();
    }

    await pg.query("COMMIT");
  } catch (e) {
    await pg.query("ROLLBACK");
    throw e;
  }
}

// 가시성 타임아웃 연장(긴 처리 대비)
async function extendVisibility(messages, extraSec = 60) {
  if (!messages.length) return;
  const Entries = messages.map((m, i) => ({
    Id: String(i),
    ReceiptHandle: m.ReceiptHandle,
    VisibilityTimeout: VISIBILITY + extraSec,
  }));
  try {
    await sqs
      .changeMessageVisibilityBatch({ QueueUrl: QURL, Entries })
      .promise();
  } catch (e) {
    // 연장 실패는 치명적이지 않으므로 로그만
    console.warn("[worker] visibility-extend failed", e?.message || e);
  }
}

// 배치 삭제(성공 처리된 메시지 일괄 삭제)
async function deleteBatch(messages) {
  if (!messages.length) return;
  const Entries = messages.map((m, i) => ({
    Id: String(i),
    ReceiptHandle: m.ReceiptHandle,
  }));
  await sqs
    .deleteMessageBatch({
      QueueUrl: QURL,
      Entries,
    })
    .promise();
}

async function receiveBatch() {
  const r = await sqs
    .receiveMessage({
      QueueUrl: QURL,
      MaxNumberOfMessages: BATCH,
      WaitTimeSeconds: LONG_POLL, // 롱폴링
      VisibilityTimeout: VISIBILITY,
      MessageAttributeNames: ["All"],
      AttributeNames: ["MessageGroupId", "ApproximateReceiveCount"],
    })
    .promise();
  return r.Messages || [];
}

function groupByMessageGroupId(messages) {
  const groups = new Map();
  for (const m of messages) {
    // FIFO 속성: Attributes.MessageGroupId
    const gid = (m.Attributes && m.Attributes.MessageGroupId) || "default";
    if (!groups.has(gid)) groups.set(gid, []);
    groups.get(gid).push(m);
  }
  return groups;
}

async function processGroup(pg, groupId, groupMsgs) {
  // 같은 그룹은 순서 보존 → 순차 처리
  // 처리 중 장시간 걸릴 수 있으므로 가시성 연장 타이머 가동
  const renewTimer = setInterval(() => {
    extendVisibility(groupMsgs, 60).catch(() => {});
  }, Math.floor(VISIBILITY * 0.6) * 1000);

  try {
    const dels = [];
    for (const m of groupMsgs) {
      try {
        const body = JSON.parse(m.Body);

        if (body.type === "payment" && body.status === "APPROVED") {
          // 결제 상태 upsert
          await pg.query(
            `
            INSERT INTO payments(order_id, provider, intent_id, status, amount)
            VALUES ($1,'mock',$2,$3,$4)
            ON CONFLICT (order_id) DO UPDATE SET status=$3, amount=$4;
          `,
            [body.intentId, body.intentId, body.status, body.amount || 0]
          );
        } else if (body.type === "commit") {
          await commitOrder(pg, body);
        }

        dels.push(m);
      } catch (e) {
        // 그룹 내 단일 메시지 에러: 삭제하지 않음(재시도)
        console.error(`[worker][group=${groupId}] message error`, e);
      }
    }

    // 그룹 내 성공 처리분만 삭제
    if (dels.length) {
      await deleteBatch(dels);
    }
  } finally {
    clearInterval(renewTimer);
  }
}

async function run() {
  const pg = await getClient();

  while (true) {
    const msgs = await receiveBatch();
    if (!msgs.length) continue;

    // 1) 그룹핑
    const byGroup = groupByMessageGroupId(msgs);

    // 2) 그룹 간 병렬 처리(배치 크기 ≤ 10 이므로 과도한 동시성 아님)
    const tasks = [];
    for (const [gid, gmsgs] of byGroup.entries()) {
      tasks.push(processGroup(pg, gid, gmsgs));
    }
    await Promise.all(tasks);
  }
}

run().catch((e) => {
  console.error("[worker] fatal", e);
  process.exit(1);
});
