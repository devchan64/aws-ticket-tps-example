import { Client } from "pg";

export async function getClient() {
  const secret = JSON.parse(process.env.DB_SECRET_JSON || "{}");
  const client = new Client({
    host: process.env.DB_HOST,
    database: process.env.DB_NAME,
    user: secret.username,
    password: secret.password,
    // Aurora 내에서 TLS 필요 시 주석 해제
    // ssl: { rejectUnauthorized: false }
  });
  await client.connect();
  return client;
}
