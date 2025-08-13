import { Agent, fetch } from "undici";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import { parse } from "yaml";

// ENV
const DURATION_SEC = parseInt(process.env.DURATION_SEC || "60", 10);
const TARGET_RPS = parseInt(process.env.TARGET_RPS || "4000", 10);
const CONCURRENCY = parseInt(process.env.CONCURRENCY || "600", 10);
const REPORT_EVERY_MS = 1000;
const SCENARIO_FILE = process.env.SCENARIO_FILE || "/opt/ticket/scenario.yaml";
const PUBLIC_BASE = process.env.PUBLIC_BASE;   // e.g. https://{ALB}/public
const CONFIRM_BASE = process.env.CONFIRM_BASE; // e.g. https://{ALB}
if (!PUBLIC_BASE || !CONFIRM_BASE) {
  console.error("PUBLIC_BASE and CONFIRM_BASE are required");
  process.exit(2);
}

// scenario YAML: 
// mode: public_only | mix | ramp
// mix: publicRatio: 0.7
// ramp: stages: [{durationSec: 20, rpsFactor: 0.3}, ...]
const scenario = parse(fs.readFileSync(SCENARIO_FILE, "utf8"));

const agent = new Agent({ keepAliveTimeout: 30_000, keepAliveMaxTimeout: 60_000, connections: CONCURRENCY });

const metrics = {
  start: Date.now(),
  sent: 0, ok: 0, err: 0,
  lat: [], // ms
  perSec: []
};

function sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }

async function doPublic() {
  const t0 = performance.now();
  const r = await fetch(`${PUBLIC_BASE}/ping`, { dispatcher: agent }).catch(e => ({ ok:false, status:0, _e:e }));
  const t1 = performance.now();
  if (!r.ok) { metrics.err++; return; }
  metrics.ok++;
  metrics.lat.push(t1 - t0);
}

async function doConfirm() {
  const t0 = performance.now();
  const idem = randomUUID();
  const r = await fetch(`${CONFIRM_BASE}/confirm`, {
    method: "POST",
    headers: { "content-type":"application/json", "Idempotency-Key": idem },
    body: JSON.stringify({ userId: `u-${randomUUID()}`, eventId: "EVT", seat: "S1-1" }),
    dispatcher: agent
  }).catch(e => ({ ok:false, status:0, _e:e }));
  const t1 = performance.now();
  if (!r.ok) { metrics.err++; return; }
  metrics.ok++;
  metrics.lat.push(t1 - t0);
}

function pickOperation() {
  if (scenario.mode === "public_only") return doPublic;
  if (scenario.mode === "mix") {
    const p = Math.random();
    return p < (scenario.publicRatio ?? 0.7) ? doPublic : doConfirm;
  }
  // default
  return doPublic;
}

function rpsForNow(baseRps){
  if (scenario.mode !== "ramp") return baseRps;
  const elapsed = (Date.now() - metrics.start) / 1000;
  let acc = 0;
  for (const st of scenario.stages) {
    acc += st.durationSec;
    if (elapsed <= acc) return Math.floor(baseRps * st.rpsFactor);
  }
  return baseRps;
}

async function run() {
  const end = metrics.start + DURATION_SEC * 1000;
  let inFlight = 0;
  let scheduled = 0;
  let lastSecMark = Math.floor((Date.now() - metrics.start)/1000);

  (async () => {
    while (Date.now() < end) {
      const nowSec = Math.floor((Date.now() - metrics.start)/1000);
      if (nowSec !== lastSecMark) {
        lastSecMark = nowSec;
        metrics.perSec[nowSec] = { sent: metrics.sent, ok: metrics.ok, err: metrics.err };
      }
      await sleep(REPORT_EVERY_MS);
    }
  })();

  while (Date.now() < end) {
    const target = rpsForNow(TARGET_RPS);
    const shouldHave = Math.floor(((Date.now() - metrics.start)/1000 + 1) * target);
    while (scheduled < shouldHave && inFlight < CONCURRENCY) {
      scheduled++; inFlight++; metrics.sent++;
      const op = pickOperation();
      op().catch(()=>{metrics.err++;}).finally(()=>{ inFlight--; });
    }
    await sleep(1);
  }
  while (inFlight > 0) await sleep(10);

  const s = [...metrics.lat].sort((a,b)=>a-b);
  const q = (p)=> s.length ? s[Math.floor((s.length-1)*p)] : 0;
  const avg = s.length ? s.reduce((a,b)=>a+b,0)/s.length : 0;

  const result = {
    startedAt: new Date(metrics.start).toISOString(),
    durationSec: DURATION_SEC,
    targetRps: TARGET_RPS,
    sent: metrics.sent, ok: metrics.ok, err: metrics.err,
    p50: q(0.50), p90: q(0.90), p95: q(0.95), p99: q(0.99), avg
  };
  console.log(JSON.stringify(result));
}

run().then(()=>process.exit(0));
