/**
 * apps/confirm-worker/src/db/pg.js
 */
import { Client } from "pg";

export async function getClient() {
  const secret = JSON.parse(process.env.DB_SECRET_JSON || "{}");
  const config = {
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    user: secret.username,
    password: secret.password,
    // ssl: { rejectUnauthorized: false }, // Aurora 내부 TLS 필요 시
  };

  if (!config.host || !config.database || !config.user || !config.password) {
    throw new Error(
      "[pg] missing db config (check DB_HOST, DB_NAME, DB_SECRET_JSON{username,password})"
    );
  }

  const client = new Client(config);
  await client.connect();
  return client;
}
