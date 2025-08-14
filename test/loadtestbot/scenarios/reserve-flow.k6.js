import http from 'k6/http';
import { sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const RATE = Number(__ENV.RATE || 500);
const DURATION = __ENV.DURATION || '300s';

export const options = {
  scenarios: {
    flow: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.min(5000, RATE * 2),
      maxVUs: Math.min(20000, RATE * 4)
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    http_req_duration: ['p(95)<400']
  }
};

export default function () {
  const userId = `u-${__ITER}-${Date.now()}`;
  const eventId = __ENV.EVENT_ID || 'event-0001';

  // enter
  const ej = http.post(`${BASE_URL}/public/enter`, JSON.stringify({ userId, eventId }), {
    headers: { 'content-type': 'application/json' }, timeout: '2s'
  }).json();

  // hold
  const hj = http.post(`${BASE_URL}/public/hold`, JSON.stringify({ eventId, seatId: 'R1C1' }), {
    headers: { 'content-type': 'application/json', 'x-room-token': ej.roomToken }, timeout: '2s'
  }).json();

  // payment-intent (헤더: Idempotency-Key 필수)
  http.post(`${BASE_URL}/confirm/payment-intent`, JSON.stringify({
    userId, eventId, seatIds: ['R1C1']
  }), {
    headers: { 'content-type': 'application/json', 'Idempotency-Key': `${userId}-idem` },
    timeout: '2s'
  });

  // 약간의 간격
  sleep(0.05);
}

export function handleSummary(data) {
  const sum = {
    metrics: {
      http_reqs: data.metrics.http_reqs?.values?.count || 0,
      http_req_failed: data.metrics.http_req_failed?.values?.rate || 0,
      http_req_duration: {
        p50: data.metrics.http_req_duration?.values['p(50)'] || 0,
        p95: data.metrics.http_req_duration?.values['p(95)'] || 0,
        p99: data.metrics.http_req_duration?.values['p(99)'] || 0
      }
    }
  };
  console.log('K6_SUMMARY=' + JSON.stringify(sum));
  return {};
}
