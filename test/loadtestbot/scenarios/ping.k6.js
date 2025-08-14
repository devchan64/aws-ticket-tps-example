import http from 'k6/http';
import { Trend, Counter, Rate } from 'k6/metrics';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const RATE = Number(__ENV.RATE || 5000);       // per second
const DURATION = __ENV.DURATION || '300s';
const RAMP_UP = __ENV.RAMP_UP || '60s';

const httpRT = new Trend('http_rt', true);
const httpErr = new Rate('http_error');
const httpCnt = new Counter('http_reqs_ok');

export const options = {
  scenarios: {
    fixed_rate: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.min(5000, RATE * 2),
      maxVUs: Math.min(20000, RATE * 4),
      startTime: '0s'
    }
  },
  thresholds: {
    http_rt:   [`p(95)<${Number(__ENV.THRESH_P95_MS || 200)}`],
    http_error: [`rate<${Number(__ENV.THRESH_ERR_RATE || 0.01)}`]
  },
  discardResponseBodies: true,
  setupTimeout: RAMP_UP
};

export default function () {
  const res = http.get(`${BASE_URL}/public/ping`, { timeout: '2s' });
  const ok = res.status === 200;
  httpErr.add(!ok);
  if (ok) httpCnt.add(1);
  httpRT.add(res.timings.duration);
  check(res, { 'status is 200': r => r.status === 200 });
  sleep(0); // cooperative yield
}

// 요약 JSON을 한 줄로 출력해 수집기를 단순화
export function handleSummary(data) {
  const sum = {
    start: data.state.testRunDurationMs ? Date.now() - data.state.testRunDurationMs : Date.now(),
    metrics: {
      http_reqs: data.metrics.http_reqs?.values?.count || 0,
      http_req_failed: data.metrics.http_req_failed?.values?.rate || 0,
      http_rt: {
        p50: data.metrics.http_rt?.values['p(50)'] || 0,
        p95: data.metrics.http_rt?.values['p(95)'] || 0,
        p99: data.metrics.http_rt?.values['p(99)'] || 0
      }
    }
  };
  console.log('K6_SUMMARY=' + JSON.stringify(sum));
  return {};
}
