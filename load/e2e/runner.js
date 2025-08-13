import { fetch, Agent } from "undici";
import { randomUUID } from "crypto";
import fs from "node:fs";
import path from "node:path";

const cfg = JSON.parse(fs.readFileSync(path.join(process.cwd(), "load/e2e/scenario_e2e.json"), "utf8"));
const VUS = Number(process.env.VUS || cfg.vus || 50);
const DURATION = Number(process.env.DURATION || cfg.durationSec || 60);
const EVENT = process.env.EVENT_ID || cfg.eventId || "EVT";
const POOL = Number(process.env.SEATS_POOL || cfg.seatsPool || 10000);
const BASE_PUBLIC = process.env.PUBLIC_BASE || cfg.base.public;
const BASE_CONFIRM = process.env.CONFIRM_BASE || cfg.base.confirm;
const RAMP = cfg.ramp || [{ atSec: 0, rps: 1000 }];

if (!BASE_PUBLIC || !BASE_CONFIRM) {
  console.error("Set base.public and base.confirm (ALB/CF URL).");
  process.exit(2);
}

const agent = new Agent({ connections: 2000, keepAliveTimeout: 30_000, keepAliveMaxTimeout: 60_000 });
const metrics = { start: Date.now(), sent: 0, ok: 0, err: 0, lat: [] };
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function pickSeat() {
  const n = Math.floor(Math.random() * POOL) + 1;
  return `S${n}`;
}
function targetRpsAt(tSec) {
  let cur = RAMP[0].rps;
  for (const r of RAMP) if (tSec >= r.atSec) cur = r.rps;
  return cur;
}

async function oneFlow(id) {
  const t0 = performance.now();
  try {
    const userId = `u-${id}-${randomUUID().slice(0,8)}`;
    // 1) enter
    const enter = await fetch(`${BASE_PUBLIC}/public/enter`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ userId, eventId: EVENT }), dispatcher: agent
    }).then(r => r.json());
    const token = enter.roomToken;

    // 2) hold
    const seatId = pickSeat();
    const hold = await fetch(`${BASE_PUBLIC}/public/hold`, {
      method: "POST",
      headers: { "content-type": "application/json", "X-Room-Token": token },
      body: JSON.stringify({ eventId: EVENT, seatId }),
      dispatcher: agent
    }).then(async r => ({ ok: r.ok, json: await r.json() }));
    if (!hold.ok) throw new Error("hold_failed");

    // 3) payment-intent
    const idem = randomUUID();
    const intent = await fetch(`${BASE_CONFIRM}/confirm/payment-intent`, {
      method: "POST",
      headers: { "content-type": "application/json", "Idempotency-Key": idem },
      body: JSON.stringify({ userId, eventId: EVENT, seatIds: [seatId] }),
      dispatcher: agent
    }).then(r => r.json());

    // 4) payment-callback (모의 PG 승인)
    await fetch(`${BASE_CONFIRM}/confirm/payment-callback`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ intentId: intent.intentId, status: "APPROVED", amount: 10000, eventId: EVENT }),
      dispatcher: agent
    });

    // 5) commit
    await fetch(`${BASE_CONFIRM}/confirm/commit`, {
      method: "POST",
      headers: { "content-type": "application/json", "Idempotency-Key": idem },
      body: JSON.stringify({ intentId: intent.intentId, eventId: EVENT, seatIds: [seatId], userId }),
      dispatcher: agent
    });

    const t1 = performance.now();
    metrics.ok++; metrics.lat.push(t1 - t0);
  } catch (e) {
    metrics.err++;
  } finally {
    metrics.sent++;
  }
}

async function vuLoop(id) {
  const endAt = metrics.start + DURATION * 1000;
  while (Date.now() < endAt) {
    // pacing: RPS 기반 틱 스케줄링
    const elapsed = (Date.now() - metrics.start) / 1000;
    const targetRps = targetRpsAt(Math.floor(elapsed));
    // VU 당 목표 RPS 분배(대략)
    const vuRps = Math.max(1, Math.floor(targetRps / VUS));
    const interval = Math.max(1, Math.floor(1000 / vuRps));
    const startTick = Date.now();
    await oneFlow(id);
    const spent = Date.now() - startTick;
    const wait = interval - spent;
    if (wait > 0) await sleep(wait);
  }
}

async function main() {
  console.log(`E2E start: VUs=${VUS}, duration=${DURATION}s, event=${EVENT}`);
  const vus = [];
  for (let i = 0; i < VUS; i++) vus.push(vuLoop(i+1));

  // per-second snapshot
  (async () => {
    let last = 0;
    while ((Date.now() - metrics.start) / 1000 < DURATION) {
      await sleep(1000);
      const nowSent = metrics.sent; const sec = Math.floor((Date.now()-metrics.start)/1000);
      const rps = nowSent - last; last = nowSent;
      process.stdout.write(`t=${sec}s sent=${metrics.sent} ok=${metrics.ok} err=${metrics.err} rps~${rps}\r`);
    }
  })();

  await Promise.all(vus);
  const s = metrics.lat.sort((a,b)=>a-b);
  const q = (p)=> s.length? s[Math.floor((s.length-1)*p)] : 0;
  const avg = s.length? s.reduce((a,b)=>a+b,0)/s.length : 0;

  const result = {
    sent: metrics.sent, ok: metrics.ok, err: metrics.err,
    p50: q(0.50), p90: q(0.90), p95: q(0.95), p99: q(0.99), avg
  };
  console.log("\n", result);
  fs.writeFileSync(path.join(process.cwd(), "load/e2e/result.json"), JSON.stringify(result, null, 2));
  console.log("✔ result: load/e2e/result.json");
}
main().catch(e => { console.error(e); process.exit(1); });
