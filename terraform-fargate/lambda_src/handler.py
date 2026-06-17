"""Render a SAST JSON report (written to S3 by the scanner) into an HTML page
stored alongside it. Triggered by S3 ObjectCreated on *.json.

The notification filter is suffix ".json" and this writes ".html", so it does
not re-trigger itself. The bucket is KMS-encrypted; the renderer role has
kms:Decrypt (for GetObject) and GenerateDataKey/Encrypt (for PutObject).
"""

import json
import urllib.parse

import boto3

s3 = boto3.client("s3")

SEV_COLOR = {
    "HIGH": "#e74c3c",
    "MEDIUM": "#e67e22",
    "LOW": "#f1c40f",
    "NONE": "#2ecc71",
}


def _row(f):
    return (
        "<tr>"
        f"<td>{f.get('severity', '')}</td>"
        f"<td>{f.get('rule', '')}</td>"
        f"<td>{f.get('file', '')}</td>"
        f"<td>{f.get('line', '')}</td>"
        f"<td>{f.get('description', '')}</td>"
        "</tr>"
    )


def _render(report):
    sev = report.get("severity", "NONE")
    summary = report.get("summary", {})
    rows = "".join(_row(f) for f in report.get("findings", []))
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>SAST Report</title>
<style>
 body{{font-family:system-ui,sans-serif;margin:2rem;color:#222}}
 .badge{{display:inline-block;padding:.3rem .8rem;border-radius:.4rem;color:#fff;
   background:{SEV_COLOR.get(sev, '#777')}}}
 table{{border-collapse:collapse;width:100%;margin-top:1rem}}
 th,td{{border:1px solid #ddd;padding:.5rem;text-align:left;font-size:.9rem}}
 th{{background:#f4f4f4}}
</style></head><body>
 <h1>SAST Scan Report</h1>
 <p>Repo: <b>{report.get('repo', '')}</b> &middot;
    PR: <b>{report.get('pr', '')}</b> &middot;
    {report.get('timestamp', '')}</p>
 <p>Overall severity: <span class="badge">{sev}</span></p>
 <p>High: {summary.get('high', 0)} &middot;
    Medium: {summary.get('medium', 0)} &middot;
    Low: {summary.get('low', 0)}</p>
 <table>
  <thead><tr><th>Severity</th><th>Rule</th><th>File</th><th>Line</th>
   <th>Description</th></tr></thead>
  <tbody>{rows or '<tr><td colspan="5">No findings 🎉</td></tr>'}</tbody>
 </table>
</body></html>"""


def handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not key.endswith(".json"):
            continue
        obj = s3.get_object(Bucket=bucket, Key=key)
        report = json.loads(obj["Body"].read())
        html_key = key[:-len(".json")] + ".html"
        s3.put_object(
            Bucket=bucket,
            Key=html_key,
            Body=_render(report).encode("utf-8"),
            ContentType="text/html",
        )
    return {"ok": True}
