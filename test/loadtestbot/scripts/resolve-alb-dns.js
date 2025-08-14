// test/e2e/scripts/resolve-alb-dns.js
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '.env') });

const REGION = process.env.REGION || 'ap-northeast-2';
const INFRA_OUT = process.env.INFRA_OUT || path.resolve(__dirname, '..', '..', '..', 'infra', 'out');

function tryResolveFromInfra() {
  const p = path.resolve(INFRA_OUT, REGION, 'alb.json');
  if (!fs.existsSync(p)) return null;

  try {
    const j = JSON.parse(fs.readFileSync(p, 'utf-8'));
    const dns = j.DNSName || j.dns || j.albDns || null;
    if (!dns) return null;
    return `https://${dns}`;
  } catch {
    return null;
  }
}

const current = process.env.BASE_URL;
if (!current) {
  const url = tryResolveFromInfra();
  if (url) {
    process.env.BASE_URL = url;
    console.log(`[resolve-alb-dns] BASE_URL = ${url}`);
  } else {
    console.warn('[resolve-alb-dns] Failed to resolve ALB DNS. Set BASE_URL in .env');
  }
} else {
  console.log(`[resolve-alb-dns] BASE_URL (env) = ${current}`);
}
