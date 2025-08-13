import AWS from "aws-sdk";
const region = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION;
export const sqs = new AWS.SQS({ region });
export const QURL = process.env.SQS_URL; // dataplane.json에서 주입됨(02_task_defs.sh)
