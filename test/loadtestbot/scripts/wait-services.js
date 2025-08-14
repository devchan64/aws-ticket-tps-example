import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';
import { request } from '@playwright/test';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '.env') });

const BASE_URL = process.env.BASE_URL;
const TIMEOUT_MS = 60_000;
const INTERVAL_MS = 2_000;

async function waitHealth(endpoint) {
  const start = Date.now();
  const ctx = await request.newContext();
  while (Date.now() - start < TIMEOUT_MS) {
    try {
      const res = await ctx.get(`${BASE_URL}${endpoint}`, { timeout: 5000 });
      if (res.ok()) {
        const json = await res.json();
        if (json && json.ok) {
          console.log(`[wait] ${endpoint} ok`);
          return;
        }
      }
    } catch {}
    await new Promise(r => setTimeout(r, INTERVAL_MS));
  }
  throw new Error(`Timeout waiting for ${endpoint}`);
}

(async () => {
  if (!BASE_URL) throw new Error('BASE_URL not set');
  await waitHealth('/public/health');
  await waitHealth('/confirm/health');
  console.log('All services healthy');
})();
