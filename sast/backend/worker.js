// SQS consumer for the SAST gate.
//
// Long-polls the scan-jobs queue, scans each job's files, writes the full
// report to S3 (which triggers the report-renderer Lambda) and updates the
// job's DynamoDB row to DONE so GET /result can return the verdict.
//
// Failure handling = "no request is ever lost":
//   - A handler that throws does NOT delete its message. The message becomes
//     visible again after the queue's visibility timeout and is retried.
//   - After maxReceiveCount (4) failed attempts SQS moves it to the DLQ, which
//     preserves it and fires the CloudWatch alarm -> SNS to DevOps.

import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from '@aws-sdk/client-sqs';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { CloudWatchClient, PutMetricDataCommand } from '@aws-sdk/client-cloudwatch';
import { scanCode } from './scanner.js';

const REGION = process.env.AWS_REGION || 'us-east-1';
const QUEUE_URL = process.env.SCAN_QUEUE_URL;
const REPORTS_BUCKET = process.env.REPORTS_BUCKET;
const METRICS_TABLE = process.env.METRICS_TABLE;
// Custom-metric namespace; point a Grafana CloudWatch data source at this.
const METRICS_NAMESPACE = process.env.METRICS_NAMESPACE || 'SAST/Scanner';

const sqs = new SQSClient({ region: REGION });
const s3 = new S3Client({ region: REGION });
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
const cw = new CloudWatchClient({ region: REGION });

// ---------------------------------------------------------------------------
// Publish business metrics to CloudWatch so they can be graphed (e.g. Grafana):
//   ScansCompleted    -> Sum gives scans/day; throughput over time
//   HighSeverityScan  -> Sum(HighSeverityScan)/Sum(ScansCompleted) = HIGH rate
//   ScanDurationMs    -> Average / p99 scan latency
//   FindingsTotal / HighFindings -> volume of issues found
// Best-effort: a metrics failure must NOT fail (and re-queue) the scan, so this
// swallows its own errors. No per-repo dimension on purpose — that would
// multiply metric cardinality (and cost); add one only if you need per-repo cuts.
// ---------------------------------------------------------------------------
async function publishMetrics({ severity, summary, durationMs }) {
  try {
    const dims = [{ Name: 'Service', Value: 'sast-scanner' }];
    await cw.send(
      new PutMetricDataCommand({
        Namespace: METRICS_NAMESPACE,
        MetricData: [
          { MetricName: 'ScansCompleted', Unit: 'Count', Value: 1, Dimensions: dims },
          { MetricName: 'HighSeverityScan', Unit: 'Count', Value: severity === 'HIGH' ? 1 : 0, Dimensions: dims },
          { MetricName: 'ScanDurationMs', Unit: 'Milliseconds', Value: durationMs, Dimensions: dims },
          { MetricName: 'FindingsTotal', Unit: 'Count', Value: summary.total, Dimensions: dims },
          { MetricName: 'HighFindings', Unit: 'Count', Value: summary.high, Dimensions: dims },
        ],
      })
    );
  } catch (err) {
    console.error('metric publish failed (non-fatal):', err.message);
  }
}

function overallSeverity(findings) {
  if (findings.some((f) => f.severity === 'HIGH')) return 'HIGH';
  if (findings.some((f) => f.severity === 'MEDIUM')) return 'MEDIUM';
  if (findings.length) return 'LOW';
  return 'NONE';
}

async function handleJob(message) {
  const startedAt = Date.now();
  const { jobId, repo, pr, timestamp, files } = JSON.parse(message.Body);

  const findings = [];
  for (const f of files) {
    if (!f || typeof f.code !== 'string') continue;
    findings.push(...scanCode(f.code, f.filename || 'untitled.js'));
  }

  const severity = overallSeverity(findings);
  const summary = {
    total: findings.length,
    high: findings.filter((v) => v.severity === 'HIGH').length,
    medium: findings.filter((v) => v.severity === 'MEDIUM').length,
    low: findings.filter((v) => v.severity === 'LOW').length,
  };

  const safeStamp = timestamp.replace(/[:.]/g, '-');
  const key = `${repo}/${pr || 'manual'}/${safeStamp}.json`;

  const report = {
    repo,
    pr: String(pr || ''),
    timestamp,
    severity,
    summary,
    // shaped to match what the report-renderer Lambda expects
    findings: findings.map((v) => ({
      severity: v.severity,
      rule: v.id,
      file: v.file,
      line: v.line,
      description: v.description,
    })),
  };

  // Full report -> S3. The S3 event triggers the Lambda, which renders .html.
  await s3.send(
    new PutObjectCommand({
      Bucket: REPORTS_BUCKET,
      Key: key,
      Body: JSON.stringify(report, null, 2),
      ContentType: 'application/json',
    })
  );

  // Flip the job row to DONE so /result returns the verdict. "status" is a
  // DynamoDB reserved word, hence the #s alias.
  await ddb.send(
    new UpdateCommand({
      TableName: METRICS_TABLE,
      Key: { repo, scan_id: jobId },
      UpdateExpression:
        'SET #s = :done, severity = :sev, high = :h, medium = :m, low = :l, s3_key = :k',
      ExpressionAttributeNames: { '#s': 'status' },
      ExpressionAttributeValues: {
        ':done': 'DONE',
        ':sev': severity,
        ':h': summary.high,
        ':m': summary.medium,
        ':l': summary.low,
        ':k': key,
      },
    })
  );

  // Emit business metrics for dashboards (best-effort; never fails the job).
  await publishMetrics({ severity, summary, durationMs: Date.now() - startedAt });
}

export async function startWorker() {
  if (!QUEUE_URL) {
    console.error('SCAN_QUEUE_URL not set; worker not started.');
    return;
  }
  console.log('SAST worker polling', QUEUE_URL);

  for (;;) {
    try {
      const out = await sqs.send(
        new ReceiveMessageCommand({
          QueueUrl: QUEUE_URL,
          MaxNumberOfMessages: 5,
          WaitTimeSeconds: 20, // long polling
          // No VisibilityTimeout override here on purpose: inherit the queue's
          // visibility_timeout_seconds (180s) so there is ONE source of truth.
          // Setting it here previously pinned every message to 60s and made the
          // queue's setting a no-op -- the bug this fixes.
        })
      );

      const messages = out.Messages || [];
      await Promise.all(
        messages.map(async (m) => {
          try {
            await handleJob(m);
            // Only delete on success; a throw leaves it for retry -> DLQ.
            await sqs.send(
              new DeleteMessageCommand({
                QueueUrl: QUEUE_URL,
                ReceiptHandle: m.ReceiptHandle,
              })
            );
          } catch (err) {
            console.error('scan job failed, leaving for retry/DLQ:', err.message);
          }
        })
      );
    } catch (err) {
      console.error('queue poll error:', err.message);
      await new Promise((r) => setTimeout(r, 5000)); // back off, then retry
    }
  }
}
