import 'dotenv/config';
import { CloudWatchLogsClient, FilterLogEventsCommand } from '@aws-sdk/client-cloudwatch-logs';

const regions = (process.env.REGIONS || process.env.REGION || 'ap-northeast-2').split(',').map(s=>s.trim());
const LOG_GROUP = process.env.K6_LOG_GROUP || '/ecs/loadtestbot';
const LOG_PREFIX = process.env.K6_LOG_PREFIX || 'load-k6';

async function collectRegion(region, startTime, endTime) {
  const cwl = new CloudWatchLogsClient({ region });
  const cmd = new FilterLogEventsCommand({
    logGroupName: LOG_GROUP,
    startTime, endTime,
    filterPattern: 'K6_SUMMARY',
    logStreamNamePrefix: LOG_PREFIX
  });
  const out = await cwl.send(cmd);
  const summaries = [];
  for (const e of (out.events || [])) {
    const m = (e.message || '').match(/K6_SUMMARY=(\{.*\})/);
    if (m) summaries.push(JSON.parse(m[1]));
  }
  return summaries;
}

(async () => {
  const end = Date.now();
  const start = end - Number(process.env.COLLECT_WINDOW_MS || 30*60*1000); // 최근 30분
  const result = {};
  for (const r of regions) {
    result[r] = await collectRegion(r, start, end);
  }
  console.log(JSON.stringify({ collectedAt: end, summaries: result }, null, 2));
})();
