import json
import boto3
from datetime import datetime

s3 = boto3.client("s3")

def handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        if not key.endswith(".json"):
            continue
        response = s3.get_object(Bucket=bucket, Key=key)
        report = json.loads(response["Body"].read().decode("utf-8"))
        html = render_html(report, key)
        html_key = key.replace(".json", ".html")
        s3.put_object(
            Bucket=bucket,
            Key=html_key,
            Body=html.encode("utf-8"),
            ContentType="text/html"
        )
        print(f"Rendered HTML report written to s3://{bucket}/{html_key}")
    return {"statusCode": 200, "body": "OK"}

def render_html(report, source_key):
    vulns = report.get("vulnerabilities", [])
    summary = report.get("summary", {})
    scanned_at = report.get("scannedAt", datetime.utcnow().isoformat())
    filename = report.get("filename", source_key)
    high = summary.get("high", 0)
    medium = summary.get("medium", 0)
    low = summary.get("low", 0)
    total = summary.get("totalVulnerabilities", len(vulns))
    rows = ""
    for v in vulns:
        sev = v.get("severity", "")
        rows += "<tr>"
        rows += "<td>" + v.get("id", "") + "</td>"
        rows += "<td>" + v.get("name", "") + "</td>"
        rows += "<td>" + sev + "</td>"
        rows += "<td>" + v.get("file", "") + " line " + str(v.get("line", "")) + "</td>"
        rows += "<td>" + v.get("evidence", "") + "</td>"
        rows += "<td>" + v.get("message", "") + "</td>"
        rows += "</tr>"
    return (
        "<html><body>"
        "<h1>SAST Scan Report: " + filename + "</h1>"
        "<p>Scanned at: " + scanned_at + "</p>"
        "<p>HIGH: " + str(high) + " | MEDIUM: " + str(medium) + " | LOW: " + str(low) + " | TOTAL: " + str(total) + "</p>"
        "<table border='1'><tr><th>ID</th><th>Name</th><th>Severity</th><th>Location</th><th>Evidence</th><th>Message</th></tr>"
        + rows +
        "</table></body></html>"
    )
