import { expect } from '@playwright/test';

export function expectNonEmptyString(v, name = 'value') {
  expect(typeof v).toBe('string');
  expect(v.length).toBeGreaterThan(0);
}
