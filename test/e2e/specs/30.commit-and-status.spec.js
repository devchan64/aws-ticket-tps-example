import { test, expect, request } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { assertJson } from '../helpers/openapi.js';

test('POST /confirm/commit → 202 + Location, then poll /confirm/status', async () => {
  const ctx = await request.newContext();

  const idem = randomUUID();
  const body = { userId:'user-0001', eventId:'event-0001', seatIds:['R1C1'], intentId:'pi_demo' };

  const commit = await ctx.post('/confirm/commit', {
    headers: { 'Idempotency-Key': idem, 'content-type': 'application/json' },
    data: body
  });
  expect(commit.status()).toBe(202);
  const loc = commit.headers()['location'];
  expect(typeof loc).toBe('string');

  const cj = await commit.json();
  assertJson('post', '/confirm/commit', 202, cj);

  let done = false, tries = 0;
  while (!done && tries++ < 20) {
    const st = await ctx.get(`/confirm/status?idem=${encodeURIComponent(idem)}`);
    expect([200, 400, 500]).toContain(st.status());
    if (st.status() === 200) {
      const sj = await st.json();
      assertJson('get', '/confirm/status', 200, sj);
      done = true;
    } else {
      await new Promise(r => setTimeout(r, 1500));
    }
  }
  expect(done).toBeTruthy();
});
