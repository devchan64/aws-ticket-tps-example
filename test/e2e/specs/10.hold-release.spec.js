import { test, expect, request } from '@playwright/test';
import { assertJson } from '../helpers/openapi.js';

test('POST /public/hold → POST /public/release', async () => {
  const ctx = await request.newContext();

  const enter = await ctx.post('/public/enter', {
    data: { userId: 'user-0001', eventId: 'event-0001' },
    headers: { 'content-type': 'application/json' }
  });
  const { roomToken } = await enter.json();

  const hold = await ctx.post('/public/hold', {
    headers: { 'x-room-token': roomToken, 'content-type': 'application/json' },
    data: { eventId: 'event-0001', seatId: 'R1C1' }
  });
  expect(hold.status()).toBe(200);
  const hj = await hold.json();
  assertJson('post', '/public/hold', 200, hj);

  const release = await ctx.post('/public/release', {
    headers: { 'content-type': 'application/json' },
    data: { eventId: 'event-0001', seatId: 'R1C1' }
  });
  expect(release.status()).toBe(200);
  const rj = await release.json();
  assertJson('post', '/public/release', 200, rj);
});
