#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import AWS from "aws-sdk";
import { Client } from "pg";

const ROOT = path.resolve(process.cwd());
const REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || process.env.TARGET_REGION;
const DP_FILE = process.env.DATAPLANE_FILE; // infra/out/<region>/dataplane.json

if (!DP_FILE || !fs.existsSync(DP_FILE)) {
  console.error(`dataplane.json not found: ${DP_FILE}`);
  process.exit(2);
}

const dp = JSON.parse(fs.readFileSync(DP_FILE, "utf8"));
const host = dp.AuroraWriterEndpoint;
const dbname = dp.AuroraDbName || process.env.AURORA_DB_NAME || "ticketdb";
const secretArn = dp.AuroraSecretArn;

if (!host || !secretArn) {
  console.error("Aurora endpoint or secret ARN missing.");
  process.exit(3);
}

const sm = new AWS.SecretsManager({ region: REGION });

async function getSecret() {
  const s = await sm.getSecretValue({ SecretId: secretArn }).promise();
  return JSON.parse(s.SecretString || "{}");
}

async function run() {
  const secret = await getSecret();
  const client = new Client({
    host,
    database: dbname,
    user: secret.username,
    password: secret.password,
    // ssl: { rejectUnauthorized: false } // 필요 시 활성화
  });
  await client.connect();

  const sqlPath = path.join(ROOT, "tools/db/schema.sql");
  const sql = fs.readFileSync(sqlPath, "utf8");
  await client.query(sql);

  console.log("✔ schema applied.");
  await client.end();
}

run().catch(e => { console.error(e); process.exit(1); });
