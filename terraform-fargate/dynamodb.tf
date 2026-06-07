# Summary item per scan: repo, scan_id (e.g. "<pr>#<timestamp>"), severity,
# timestamp, and the S3 key of the full report. Feeds the trends dashboard.
# PAY_PER_REQUEST so an idle table costs nothing.

resource "aws_dynamodb_table" "scan_metrics" {
  name         = var.scan_metrics_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "repo"
  range_key    = "scan_id"

  attribute {
    name = "repo"
    type = "S"
  }

  attribute {
    name = "scan_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = "sast-scan-metrics" }
}
