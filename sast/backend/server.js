import express from 'express';
import cors from 'cors';
import crypto from 'crypto';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand, GetCommand } from '@aws-sdk/lib-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';
import { scanCode } from './scanner.js';
import { startWorker } from './worker.js';

const app = express();
const PORT = process.env.PORT || 3000;
const REGION = process.env.AWS_REGION || 'us-east-1';
const REPORTS_BUCKET = process.env.REPORTS_BUCKET;
const METRICS_TABLE = process.env.METRICS_TABLE;
const QUEUE_URL = process.env.SCAN_QUEUE_URL;

const s3 = new S3Client({ region: REGION });
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
const sqs = new SQSClient({ region: REGION });

// ---------------------------------------------------------------------------
// Auth: load the shared token once at startup (from SSM in AWS, env locally),
// then require a matching Bearer token on every route except the health check.
// ---------------------------------------------------------------------------
async function loadToken() {
  if (process.env.SCANNER_TOKEN) return process.env.SCANNER_TOKEN;
  const name = process.env.SCANNER_TOKEN_PARAM || '/sast/scanner-token';
  try {
    const ssm = new SSMClient({ region: REGION });
    const out = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
    return out.Parameter?.Value || null;
  } catch (err) {
    console.error('Could not load scanner token from SSM:', err.message);
    return null;
  }
}
const SCANNER_TOKEN = await loadToken();

function tokenValid(provided) {
  if (!SCANNER_TOKEN || !provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(SCANNER_TOKEN);
  // constant-time compare to avoid leaking the token via timing
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

app.use(cors());
app.use(express.json({ limit: '10mb' }));

app.use((req, res, next) => {
  if (req.path === '/health') return next(); // ALB health check must be open
  const header = req.headers.authorization || '';
  const provided = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!tokenValid(provided)) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  next();
});

// ---------------------------------------------------------------------------
// Health check. IMPORTANT: set health_check_path = "/health" in Terraform,
// otherwise the ALB checks "/" (404) and kills every task.
// ---------------------------------------------------------------------------
app.get('/health', (req, res) => {
  res.json({
    status: 'healthy',
    service: 'SAST Scanner',
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  });
});

// ---------------------------------------------------------------------------
// CI entry point (PRODUCER). The GitHub Actions workflow POSTs the PR's changed
// files; we enqueue the job and return 202 immediately. The request is now
// safely on SQS and will be scanned by a worker -- a burst of PRs queues up
// rather than overloading the scanner, and nothing is dropped.
//   Body: { repo, pr, files: [{ filename, code }] }
//   Resp: 202 { job_id, repo, status: "QUEUED" }
// The gate then polls GET /result until status is DONE.
// ---------------------------------------------------------------------------
app.post('/scan', async (req, res) => {
  try {
    const { repo, pr, files } = req.body || {};
    if (!repo || !Array.isArray(files)) {
      return res
        .status(400)
        .json({ error: 'expected { repo, pr, files: [{ filename, code }] }' });
    }

    const jobId = crypto.randomUUID();
    const timestamp = new Date().toISOString();
    const body = JSON.stringify({ jobId, repo, pr: String(pr || ''), timestamp, files });

    // SQS caps a message at 256 KB. For larger PRs, switch to the "S3 pointer"
    // pattern: upload `files` to S3 and enqueue just the object key.
    if (Buffer.byteLength(body) > 256 * 1024) {
      return res
        .status(413)
        .json({ error: 'payload exceeds the 256KB SQS message limit' });
    }

    // Write a QUEUED row first so /result can be polled immediately, even
    // before a worker picks the job up.
    await ddb.send(
      new PutCommand({
        TableName: METRICS_TABLE,
        Item: { repo, scan_id: jobId, status: 'QUEUED', pr: String(pr || ''), timestamp },
      })
    );

    await sqs.send(new SendMessageCommand({ QueueUrl: QUEUE_URL, MessageBody: body }));

    res.status(202).json({ job_id: jobId, repo, status: 'QUEUED' });
  } catch (err) {
    console.error('enqueue failed:', err);
    res.status(500).json({ error: 'enqueue failed', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Verdict lookup. The gate polls this with the repo + job_id from /scan.
//   GET /result?repo=<repo>&job_id=<id>
//   202 { status }                         while QUEUED / IN_PROGRESS
//   200 { status, severity, summary, report_url }   once DONE
// ---------------------------------------------------------------------------
app.get('/result', async (req, res) => {
  try {
    const { repo, job_id } = req.query;
    if (!repo || !job_id) {
      return res.status(400).json({ error: 'expected ?repo=&job_id=' });
    }

    const out = await ddb.send(
      new GetCommand({ TableName: METRICS_TABLE, Key: { repo, scan_id: job_id } })
    );
    const item = out.Item;
    if (!item) return res.status(404).json({ error: 'unknown job' });
    if (item.status !== 'DONE') {
      return res.status(202).json({ status: item.status });
    }

    const htmlKey = item.s3_key.replace(/\.json$/, '.html');
    const reportUrl = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: REPORTS_BUCKET, Key: htmlKey }),
      { expiresIn: 3600 }
    );

    res.json({
      status: 'DONE',
      severity: item.severity,
      summary: { high: item.high, medium: item.medium, low: item.low },
      report_url: reportUrl,
    });
  } catch (err) {
    console.error('result lookup failed:', err);
    res.status(500).json({ error: 'result lookup failed', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Ad-hoc synchronous snippet scan, handy for manual testing. No persistence.
// (The arbitrary-path /scan/file and /scan/directory endpoints were removed:
//  they were duplicated dead code and a local-file-disclosure risk in prod.)
// ---------------------------------------------------------------------------
app.post('/scan/code', (req, res) => {
  try {
    const { code, filename = 'untitled.js' } = req.body;
    if (!code) return res.status(400).json({ error: 'No code provided' });
    const results = scanCode(code, filename);
    res.json({
      success: true,
      filename,
      scannedAt: new Date().toISOString(),
      summary: {
        totalVulnerabilities: results.length,
        high: results.filter((v) => v.severity === 'HIGH').length,
        medium: results.filter((v) => v.severity === 'MEDIUM').length,
        low: results.filter((v) => v.severity === 'LOW').length,
      },
      vulnerabilities: results,
    });
  } catch (error) {
    res.status(500).json({ error: 'Scan failed', message: error.message });
  }
});

app.listen(PORT, () => {
  console.log(`SAST Scanner API listening on port ${PORT}`);
});

// ---------------------------------------------------------------------------
// Drain the queue. For the MVP this runs in-process so a single ECS service is
// both API and worker. NOTE: scans share this Node event loop, so a heavy scan
// briefly delays API responses. For production isolation, run a SECOND ECS
// service from this same image as a pure worker (RUN_WORKER unset) and set the
// API service's container to RUN_WORKER=false, then autoscale the worker
// service on the queue's ApproximateNumberOfMessagesVisible.
// ---------------------------------------------------------------------------
if (process.env.RUN_WORKER !== 'false') {
  startWorker();
}
