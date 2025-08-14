import { test, expect, request } from '@playwright/test';
import { assertJson } from '../helpers/openapi.js';

test('POST /public/enter → GET /public/room-status', async () => {
  const ctx = await request.newContext();
  const enter = await ctx.post('/public/enter', {
    data: { userId: process.env.USER_ID || 'user-0001', eventId: process.env.EVENT_ID || 'event-0001' },
    headers: { 'content-type': 'application/json' }
  });
  expect(enter.status()).toBe(200);
  const ej = await enter.json();
  assertJson('post', '/public/enter', 200, ej);

  const status = await ctx.get(`/public/room-status?token=${encodeURIComponent(ej.roomToken)}`);
  expect(status.status()).toBe(200);
  const sj = await status.json();
  assertJson('get', '/public/room-status', 200, sj);
});
