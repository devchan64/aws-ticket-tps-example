/**
 * apps/confirm-worker/src/worker.js
 */
import AWS from "aws-sdk";
import Ajv from "ajv";
import addFormats from "ajv-formats";
import SwaggerParser from "@apidevtools/swagger-parser";
import path from "node:path";
import fs from "node:fs";

const AWS_REGION = process.env.AWS_REGION || "ap-northeast-1";
AWS.config.update({ region: AWS_REGION });

const QURL = process.env.SQS_URL || "";
if (!QURL) {
  console.error("[worker] QURL is required");
  process.exit(1);
}

const sqs = new AWS.SQS({ apiVersion: "2012-11-05" });

// --- 스펙 로딩 & $ref 해제 ---
// SPEC_PATH 환경변수 우선, 없으면 모노레포 루트 기준 기본값
const CWD = process.cwd();
// /app/apps/confirm-worker 기준으로 ../../openapi/ticketing.yaml
const DEFAULT_SPEC = path.resolve(CWD, "../../openapi/ticketing.yaml");
const SPEC_PATH = process.env.SPEC_PATH || DEFAULT_SPEC;

if (!fs.existsSync(SPEC_PATH)) {
  console.error("[worker] openapi spec not found:", SPEC_PATH);
  process.exit(1);
}

const deref = await SwaggerParser.dereference(SPEC_PATH); // 모든 $ref 해제됨
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
  try {
    body = JSON.parse(m.Body);
  } catch {
    throw new Error("invalid_json");
  }

  const ok = validateMsg(body);
  if (!ok) {
    const detail = ajv.errorsText(validateMsg.errors, { separator: " | " });
    const err = new Error("schema_validation_failed");
    err.details = detail;
    throw err;
  }

  const { payload, idem } = body;
  // TODO: DDB 잠금 재검증 → PG 트랜잭션 확정 → 잠금 해제 등 도메인 로직
  // ...
  return { idem, ok: true };
}

// --- 폴링 루프 ---
const BATCH = Math.min(parseInt(process.env.BATCH_SIZE || "10", 10), 10);
const WAIT = parseInt(process.env.WAIT_TIME || "20", 10);
const VIS = parseInt(process.env.VISIBILITY_TIMEOUT || "60", 10);

// 실패 백오프 (가시성 연장) 계산: 2^retries * base(=5) 초, 최대 cap(=300s)
function calcBackoffSeconds(retries) {
  const base = 5;
  const cap = 300;
  const sec = Math.min(cap, Math.pow(2, Math.max(0, retries - 1)) * base);
  return Math.max(sec, base);
}

async function pollOnce() {
  const { Messages } = await sqs
    .receiveMessage({
      QueueUrl: QURL,
      MaxNumberOfMessages: BATCH,
      WaitTimeSeconds: WAIT,
      VisibilityTimeout: VIS,
      AttributeNames: ["ApproximateReceiveCount"],
    })
    .promise();

  if (!Messages || !Messages.length) return;

  const successDeletes = [];

  for (const m of Messages) {
    const receiveCount = parseInt(
      m.Attributes?.ApproximateReceiveCount || "1",
      10
    );

    try {
      const res = await handle(m);
      successDeletes.push({ Id: m.MessageId, ReceiptHandle: m.ReceiptHandle });
      console.log("[worker] processed", {
        messageId: m.MessageId,
        receiveCount,
        idem: res?.idem,
      });
    } catch (e) {
      const msg = e?.message || String(e);
      const details = e?.details;
      console.error("[worker] handle_error", {
        messageId: m.MessageId,
        receiveCount,
        error: msg,
        details,
      });

      // 실패: 삭제하지 않고 가시성 연장(백오프)하여 재시도 유도.
      // DLQ가 연결되어 있으면 한계 횟수 초과 시 DLQ로 이동됨.
      const backoffSec = calcBackoffSeconds(receiveCount);
      try {
        await sqs
          .changeMessageVisibility({
            QueueUrl: QURL,
            ReceiptHandle: m.ReceiptHandle,
            VisibilityTimeout: backoffSec,
          })
          .promise();
        console.warn("[worker] visibility_extended", {
          messageId: m.MessageId,
          backoffSec,
        });
      } catch (visErr) {
        console.error("[worker] change_visibility_failed", {
          messageId: m.MessageId,
          error: visErr?.message || String(visErr),
        });
        // 가시성 연장 실패 시에도 삭제는 하지 않음 (재시도에 맡김)
      }
    }
  }

  if (successDeletes.length) {
    await sqs
      .deleteMessageBatch({ QueueUrl: QURL, Entries: successDeletes })
      .promise();
  }
}

(async function main() {
  console.log("[worker] start", {
    region: AWS_REGION,
    queue: QURL,
    spec: SPEC_PATH,
  });
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      await pollOnce();
    } catch (e) {
      console.error("[worker] fatal", e?.message || e);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
})();
