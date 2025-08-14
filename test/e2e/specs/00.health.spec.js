import { test, expect, request } from '@playwright/test';
import { assertJson } from '../helpers/openapi.js';

test('@smoke GET /public/health', async () => {
  const ctx = await request.newContext();
  const res = await ctx.get('/public/health');
  expect(res.status()).toBe(200);
  const j = await res.json();
  assertJson('get', '/public/health', 200, j);
});

test('@smoke GET /confirm/health', async () => {
  const ctx = await request.newContext();
  const res = await ctx.get('/confirm/health');
  expect(res.status()).toBe(200);
  const j = await res.json();
  assertJson('get', '/confirm/health', 200, j);
});
