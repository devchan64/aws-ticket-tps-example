import { test, expect, request } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { assertJson } from '../helpers/openapi.js';

test('@smoke POST /confirm/payment-intent (201 or 200 replay)', async () => {
  const ctx = await request.newContext();
  const idem = randomUUID();
  const res = await ctx.post('/confirm/payment-intent', {
    headers: { 'Idempotency-Key': idem, 'content-type': 'application/json' },
    data: { userId: 'user-0001', eventId: 'event-0001', seatIds: ['R1C1','R1C2'] }
  });
  expect([200, 201]).toContain(res.status());
  const j = await res.json();
  const status = res.status();
  assertJson('post', '/confirm/payment-intent', status, j);
});
