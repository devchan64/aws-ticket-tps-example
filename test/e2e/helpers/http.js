import { expect, request } from '@playwright/test';

export async function newHttp() {
  return await request.newContext();
}

export async function expectOkJson(res) {
  expect(res.ok()).toBeTruthy();
  const ct = res.headers()['content-type'] || '';
  expect(ct).toContain('application/json');
}
