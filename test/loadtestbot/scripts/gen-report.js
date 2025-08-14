import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { CloudWatchClient, GetMetricDataCommand } from '@aws-sdk/client-cloudwatch';

const regions = (process.env.REGIONS || process.env.REGION || 'ap-northeast-2').split(',').map(s=>s.trim());
const outDir = path.resolve(process.cwd(), 'reports');

function aggregate(json) {
  const byRegion = json.summaries;
  let totalReqs = 0;
  let maxP95 = 0, maxP99 = 0;
  let maxErrRate = 0;

  Object.values(byRegion).forEach(arr => {
    for (const s of arr) {
      totalReqs += s.metrics.http_reqs || 0;
      maxErrRate = Math.max(maxErrRate, s.metrics.http_req_failed || 0);
      const p95 = s.metrics.http_rt?.p95 || s.metrics.http_req_duration?.p95 || 0;
      const p99 = s.metrics.http_rt?.p99 || s.metrics.http_req_duration?.p99 || 0;
      maxP95 = Math.max(maxP95, p95);
      maxP99 = Math.max(maxP99, p99);
    }
  });

  const durationSec = parseInt((process.env.DURATION || '300s').replace('s',''), 10) || 300;
  const sustainedTps = Math.floor(totalReqs / durationSec);
  return { totalReqs, sustainedTps, maxP95, maxP99, maxErrRate };
}

async function albMetrics(region, start, end, albArn) {
  if (!albArn) return null;
  const cw = new CloudWatchClient({ region });
  const oneMin = 60;
  const q = [
    {
      Id: 'req',
      MetricStat: {
        Metric: { Namespace: 'AWS/ApplicationELB', MetricName: 'RequestCount', Dimensions: [{ Name: 'LoadBalancer', Value: albArn.split('/').slice(1).join('/') }] },
        Period: oneMin,
        Stat: 'Sum'
      },
      ReturnData: true
    },
    {
      Id: 'lat',
      MetricStat: {
        Metric: { Namespace: 'AWS/ApplicationELB', MetricName: 'TargetResponseTime', Dimensions: [{ Name: 'LoadBalancer', Value: albArn.split('/').slice(1).join('/') }] },
        Period: oneMin,
        Stat: 'p95'
      },
      ReturnData: true
    }
  ];
  const cmd = new GetMetricDataCommand({
    StartTime: new Date(start), EndTime: new Date(end), ScanBy: 'TimestampAscending', MetricDataQueries: q
  });
  const r = await cw.send(cmd);
  const req = r.MetricDataResults?.find(m => m.Id === 'req');
  const lat = r.MetricDataResults?.find(m => m.Id === 'lat');
  const reqSum = (req?.Values || []).reduce((a,b)=>a+b,0);
  const latMax = (lat?.Values || []).reduce((a,b)=>Math.max(a,b),0);
  const minutes = Math.max(1, ((end - start) / 60000)|0);
  return { albReqSum: reqSum, albAvgTps: Math.floor(reqSum / (minutes*60)), albP95TargetRT: Math.round(latMax*1000) };
}

(async () => {
  // 입력: collect-cloudwatch.js 출력(JSON)을 표준입력으로 받거나 파일로 전달
  const inputPath = process.argv[2];
  const data = inputPath ? JSON.parse(fs.readFileSync(inputPath, 'utf-8')) : JSON.parse(fs.readFileSync(0, 'utf-8'));
  const agg = aggregate(data);
  const now = new Date();
  const stamp = now.toISOString().replace(/[:.]/g,'-');

  let albParts = [];
  const start = data.collectedAt - (Number(process.env.DURATION?.replace('s','')) || 300)*1000 - 60*1000;
  const end = data.collectedAt + 60*1000;
  for (const r of regions) {
    const arn = process.env[`ALB_ARN_${r.replace(/-/g,'_').toUpperCase()}`] || process.env.ALB_ARN;
    if (!arn) continue;
    const m = await albMetrics(r, start, end, arn).catch(()=>null);
    if (m) albParts.push({ region: r, ...m });
  }

  const lines = [];
  lines.push(`# TPS Load Report (${stamp})`);
  lines.push('');
  lines.push(`- Duration: ${process.env.DURATION || '300s'}`);
  lines.push(`- Regions: ${regions.join(', ')}`);
  lines.push(`- Sustained TPS (from k6 summaries): **${agg.sustainedTps.toLocaleString()}**`);
  lines.push(`- Total Requests: ${agg.totalReqs.toLocaleString()}`);
  lines.push(`- p95 (max across workers): ${Math.round(agg.maxP95)} ms`);
  lines.push(`- p99 (max across workers): ${Math.round(agg.maxP99)} ms`);
  lines.push(`- Error Rate (max across workers): ${(agg.maxErrRate*100).toFixed(2)}%`);
  if (albParts.length) {
    lines.push('');
    lines.push('## ALB Metrics (CloudWatch)');
    for (const p of albParts) {
      lines.push(`- ${p.region}: RequestCount=${p.albReqSum.toLocaleString()}, avg TPS≈${p.albAvgTps.toLocaleString()}, TargetResponseTime p95≈${p.albP95TargetRT} ms`);
    }
  }
  lines.push('');
  lines.push('SLA thresholds:');
  lines.push(`- p95 < ${process.env.THRESH_P95_MS || 200} ms, error rate < ${(Number(process.env.THRESH_ERR_RATE || 0.01)*100)}%`);

  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.resolve(outDir, `tps-report-${stamp}.md`);
  fs.writeFileSync(outPath, lines.join('\n'), 'utf-8');
  console.log(`Report: ${outPath}`);
})();
