/**
 * apps/confirm-worker/src/worker.js
 */
import AWS from "aws-sdk";
import Ajv from "ajv";
import addFormats from "ajv-formats";
import SwaggerParser from "@apidevtools/swagger-parser";
import path from "node:path";

const AWS_REGION = process.env.AWS_REGION || "ap-northeast-1";
AWS.config.update({ region: AWS_REGION });
const QURL = process.env.QURL || "";
if (!QURL) { console.error("[worker] QURL is required"); process.exit(1); }
const sqs = new AWS.SQS({ apiVersion: "2012-11-05" });

// --- 스펙 로딩 & $ref 해제 ---
const specPath = path.resolve(process.cwd(), "openapi/ticketing.yaml");
const deref = await SwaggerParser.dereference(specPath); // 모든 $ref 해제됨
// 안전가드
if (!deref?.components?.schemas?.CommitSqsMessage) {
  throw new Error("CommitSqsMessage schema not found in spec");
}

// --- Ajv 컴파일 ---
const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);
const validateMsg = ajv.compile(deref.components.schemas.CommitSqsMessage);

// --- 메시지 처리 ---
async function handle(m) {
  let body;
  try { body = JSON.parse(m.Body); } catch { throw new Error("invalid_json"); }
  if (!validateMsg(body)) {
    const detail = ajv.errorsText(validateMsg.errors);
    throw new Error("schema_validation_failed: " + detail);
  }
  const { payload, idem } = body;
  // TODO: DDB 잠금 재검증 → PG 트랜잭션 확정 → 잠금 해제 등 도메인 로직
  // ...
}

// --- 폴링 루프 ---
const BATCH = Math.min(parseInt(process.env.BATCH_SIZE || "10", 10), 10);
const WAIT = parseInt(process.env.WAIT_TIME || "20", 10);
const VIS = parseInt(process.env.VISIBILITY_TIMEOUT || "60", 10);

async function pollOnce() {
  const { Messages } = await sqs.receiveMessage({
    QueueUrl: QURL, MaxNumberOfMessages: BATCH, WaitTimeSeconds: WAIT, VisibilityTimeout: VIS,
  }).promise();
  if (!Messages || !Messages.length) return;

  const dels = [];
  for (const m of Messages) {
    try { await handle(m); dels.push({ Id: m.MessageId, ReceiptHandle: m.ReceiptHandle }); }
    catch (e) { console.error("[worker] err", e?.message || e); dels.push({ Id: m.MessageId, ReceiptHandle: m.ReceiptHandle }); }
  }
  if (dels.length) await sqs.deleteMessageBatch({ QueueUrl: QURL, Entries: dels }).promise();
}

(async function main() {
  console.log("[worker] start", { region: AWS_REGION, queue: QURL });
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try { await pollOnce(); } catch (e) { console.error("[worker] fatal", e); await new Promise(r => setTimeout(r, 1000)); }
  }
})();
