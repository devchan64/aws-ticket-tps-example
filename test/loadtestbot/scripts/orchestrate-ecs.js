import 'dotenv/config';
import { ECSClient, RunTaskCommand, DescribeTasksCommand } from '@aws-sdk/client-ecs';

const regions = (process.env.REGIONS || process.env.REGION || 'ap-northeast-2').split(',').map(s=>s.trim());
const commonEnv = [
  { name: 'BASE_URL', value: process.env.BASE_URL || '' },
  { name: 'RATE', value: process.env.RATE || '5000' },
  { name: 'DURATION', value: process.env.DURATION || '300s' },
  { name: 'RAMP_UP', value: process.env.RAMP_UP || '60s' },
  { name: 'THRESH_P95_MS', value: process.env.THRESH_P95_MS || '200' },
  { name: 'THRESH_ERR_RATE', value: process.env.THRESH_ERR_RATE || '0.01' },
  { name: 'EVENT_ID', value: process.env.EVENT_ID || 'event-0001' }
];

async function runInRegion(region, scenarioFile) {
  const cluster = process.env.ECS_CLUSTER;
  const family = process.env.ECS_TASKDEF_FAMILY;
  const subnets = (process.env.ECS_TASK_SUBNETS || '').split(',').filter(Boolean);
  const sgs = (process.env.ECS_TASK_SGS || '').split(',').filter(Boolean);

  const ecs = new ECSClient({ region });
  const overrides = {
    containerOverrides: [{
      name: 'k6', // Task 정의의 컨테이너 이름
      command: ['run', `/scripts/scenarios/${scenarioFile}`],
      environment: commonEnv
    }]
  };

  const cmd = new RunTaskCommand({
    cluster,
    taskDefinition: family,
    launchType: 'FARGATE',
    count: Number(process.env.ECS_COUNT || '1'),
    networkConfiguration: {
      awsvpcConfiguration: {
        subnets, securityGroups: sgs,
        assignPublicIp: process.env.ECS_ASSIGN_PUBLIC_IP || 'ENABLED'
      }
    },
    overrides
  });

  const res = await ecs.send(cmd);
  const tasks = res.tasks?.map(t => t.taskArn) || [];
  console.log(`[ecs] ${region} started:`, tasks);

  // 간단 대기 (옵션): RUNNING 될 때까지
  const desc = new DescribeTasksCommand({ cluster, tasks });
  let tries = 0;
  while (tries++ < 30) {
    const d = await ecs.send(desc);
    const allRunning = (d.tasks || []).every(t => t.lastStatus === 'RUNNING');
    if (allRunning) break;
    await new Promise(r => setTimeout(r, 2000));
  }
  return tasks;
}

(async () => {
  const scenario = process.argv[2] || 'ping.k6.js'; // 기본 ping 시나리오
  const all = [];
  for (const r of regions) {
    const tasks = await runInRegion(r, scenario);
    all.push({ region: r, tasks });
  }
  console.log(JSON.stringify({ started: all }, null, 2));
})();
