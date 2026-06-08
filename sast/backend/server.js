import express from 'express';
import cors from 'cors';
import crypto from 'crypto';
import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { scanCode, scanFile, scanDirectory } from './scanner.js';

const app = express();
const PORT = process.env.PORT || 3000;
const REGION = process.env.AWS_REGION || 'us-east-1';
const REPORTS_BUCKET = process.env.REPORTS_BUCKET;
const METRICS_TABLE = process.env.METRICS_TABLE;

const s3 = new S3Client({ region: REGION });
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));

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

function overallSeverity(findings) {
  if (findings.some((f) => f.severity === 'HIGH')) return 'HIGH';
  if (findings.some((f) => f.severity === 'MEDIUM')) return 'MEDIUM';
  if (findings.length) return 'LOW';
  return 'NONE';
}

// ---------------------------------------------------------------------------
// CI entry point. The GitHub Actions workflow POSTs the PR's changed files;
// we scan each, persist the report, and return the verdict the gate uses.
//   Body: { repo, pr, files: [{ filename, code }] }
//   Resp: { severity, report_url, summary }
// ---------------------------------------------------------------------------
app.post('/scan', async (req, res) => {
  try {
    const { repo, pr, files } = req.body || {};
    if (!repo || !Array.isArray(files)) {
      return res
        .status(400)
        .json({ error: 'expected { repo, pr, files: [{ filename, code }] }' });
    }

    const findings = [];
    for (const f of files) {
      if (!f || typeof f.code !== 'string') continue;
      findings.push(...scanCode(f.code, f.filename || 'untitled.js'));
    }

    const severity = overallSeverity(findings);
    const timestamp = new Date().toISOString();
    const safeStamp = timestamp.replace(/[:.]/g, '-');
    const key = `${repo}/${pr || 'manual'}/${safeStamp}.json`;

    const report = {
      repo,
      pr: String(pr || ''),
      timestamp,
      severity,
      summary: {
        total: findings.length,
        high: findings.filter((v) => v.severity === 'HIGH').length,
        medium: findings.filter((v) => v.severity === 'MEDIUM').length,
        low: findings.filter((v) => v.severity === 'LOW').length,
      },
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

    // Summary item -> DynamoDB for the trends dashboard.
    await ddb.send(
      new PutCommand({
        TableName: METRICS_TABLE,
        Item: {
          repo,
          scan_id: `${pr || 'manual'}#${timestamp}`,
          timestamp,
          severity,
          high: report.summary.high,
          medium: report.summary.medium,
          low: report.summary.low,
          s3_key: key,
        },
      })
    );

    // Presigned link to the rendered HTML (Lambda writes it a moment later).
    const htmlKey = key.replace(/\.json$/, '.html');
    const reportUrl = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: REPORTS_BUCKET, Key: htmlKey }),
      { expiresIn: 3600 }
    );

    res.json({ severity, report_url: reportUrl, summary: report.summary });
  } catch (err) {
    console.error('scan failed:', err);
    res.status(500).json({ error: 'scan failed', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Existing endpoints, kept behind auth
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

// Scan a specific file on the server
app.post('/scan/file', (req, res) => {
  try {
    const { filepath } = req.body;

    if (!filepath) {
      return res.status(400).json({
        error: 'No filepath provided',
        message: 'Please provide filepath in the request body'
      });
    }

    const results = scanFile(filepath);

    res.json({
      success: true,
      filepath,
      scannedAt: new Date().toISOString(),
      summary: {
        totalVulnerabilities: results.length,
        high: results.filter(v => v.severity === 'HIGH').length,
        medium: results.filter(v => v.severity === 'MEDIUM').length,
        low: results.filter(v => v.severity === 'LOW').length
      },
      vulnerabilities: results
    });
  } catch (error) {
    res.status(500).json({
      error: 'Scan failed',
      message: error.message
    });
  }
});

// Scan an entire directory
app.post('/scan/directory', (req, res) => {
  try {
    const { dirpath } = req.body;

    if (!dirpath) {
      return res.status(400).json({
        error: 'No directory path provided',
        message: 'Please provide dirpath in the request body'
      });
    }

    const results = scanDirectory(dirpath);

    const allVulnerabilities = Object.values(results).flat();

    res.json({
      success: true,
      dirpath,
      scannedAt: new Date().toISOString(),
      summary: {
        filesScanned: Object.keys(results).length,
        totalVulnerabilities: allVulnerabilities.length,
        high: allVulnerabilities.filter(v => v.severity === 'HIGH').length,
        medium: allVulnerabilities.filter(v => v.severity === 'MEDIUM').length,
        low: allVulnerabilities.filter(v => v.severity === 'LOW').length
      },
      results
    });
  } catch (error) {
    res.status(500).json({
      error: 'Scan failed',
      message: error.message
    });
  }
});

// WARNING: /scan/file and /scan/directory read ARBITRARY paths on the
// container filesystem. That is a local-file-disclosure risk on a service
// that handles hospital code. They are fine for local debugging, but consider
// removing them from the deployed image (or restrict to an allow-listed dir).
app.post('/scan/file', (req, res) => {
  try {
    const { filepath } = req.body;
    if (!filepath) return res.status(400).json({ error: 'No filepath provided' });
    const results = scanFile(filepath);
    res.json({ success: true, filepath, vulnerabilities: results });
  } catch (error) {
    res.status(500).json({ error: 'Scan failed', message: error.message });
  }
});

app.post('/scan/directory', (req, res) => {
  try {
    const { dirpath } = req.body;
    if (!dirpath) return res.status(400).json({ error: 'No directory path provided' });
    const results = scanDirectory(dirpath);
    const all = Object.values(results).flat();
    res.json({
      success: true,
      dirpath,
      summary: { filesScanned: Object.keys(results).length, totalVulnerabilities: all.length },
      results,
    });
  } catch (error) {
    res.status(500).json({ error: 'Scan failed', message: error.message });
  }
});

// Start server
app.listen(PORT, () => {
  console.log(`
  ╔═══════════════════════════════════════════╗
  ║         SAST Scanner Server               ║
  ║         Running on port ${PORT}              ║
  ╚═══════════════════════════════════════════╝
  
  Endpoints:
  - GET  /health          - Health check
  - GET  /vulnerabilities - List supported checks
  - POST /scan/code       - Scan code snippet
  - POST /scan/file       - Scan a file
  - POST /scan/directory  - Scan a directory
  `);
});