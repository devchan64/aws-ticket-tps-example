/**
 * apps/confirm-api/src/sqs.js
 * ESM (package.json: { "type": "module" })
 */
import crypto from "crypto";
import AWS from "aws-sdk";
import { v4 as uuidv4 } from "uuid";

const REGION =
  process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "ap-northeast-1";
export const QURL = process.env.SQS_URL;
const SHARDS = parseInt(process.env.SQS_GROUP_SHARDS || "1024", 10);

if (!QURL) throw new Error("[confirm-api] SQS_URL is not set");
if (!QURL.endsWith(".fifo"))
  throw new Error("[confirm-api] SQS_URL must be a FIFO queue (.fifo)");

AWS.config.update({ region: REGION });
const sqs = new AWS.SQS({ apiVersion: "2012-11-05", region: REGION });

/** 고정 샤딩 그룹: key(주문/의도/멱등키) → 0..N-1 */
function groupIdFor(key) {
  const h = crypto.createHash("sha1").update(String(key)).digest();
  const n = h.readUInt32BE(0);
  return `g-${n % SHARDS}`;
}

/** 기본 중복 방지 ID
 * - 멱등키가 명확하면 base 그대로 사용(5분 dedup window 내 중복 차단)
 * - 멱등키가 없으면 UUID 부여(중복 방지 대신 중복 허용 전제)
 */
function dedupId(base) {
  return base ? String(base) : `${uuidv4()}`;
}

/** 단건 전송 */
export async function enqueueOne(payload, groupKey, dedupBase = groupKey) {
  const params = {
    QueueUrl: QURL,
    MessageBody: JSON.stringify(payload),
    MessageGroupId: groupIdFor(groupKey), // 샤딩된 그룹. 순서 보장이 절대적이면 groupKey 자체를 쓰는 구현으로 교체
    MessageDeduplicationId: dedupId(dedupBase),
  };
  await sqs.sendMessage(params).promise();
}

/** 최대 10개 배치 전송 */
export async function enqueueBatch(items, groupKeyFn) {
  if (!Array.isArray(items) || !items.length) return;
  for (let i = 0; i < items.length; i += 10) {
    const chunk = items.slice(i, i + 10);
    const Entries = chunk.map((p, idx) => {
      const gk = groupKeyFn(p);
      return {
        Id: String(idx),
        MessageBody: JSON.stringify(p),
        MessageGroupId: groupIdFor(gk),
        MessageDeduplicationId: dedupId(gk),
      };
    });
    await sqs.sendMessageBatch({ QueueUrl: QURL, Entries }).promise();
  }
}

export { sqs };
