# Hamza -- feel free to change/improve, I just wanted to see what everything
# looked like altogether

resource "aws_kms_key" "reports" {
  description             = "KMS key for SAST scan report encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "reports" {
  name          = "alias/sast-scan-reports"
  target_key_id = aws_kms_key.reports.key_id
}

resource "aws_s3_bucket" "scan_reports" {
  bucket = var.scan_reports_bucket_name
}

resource "aws_s3_bucket_versioning" "scan_reports" {
  bucket = aws_s3_bucket.scan_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scan_reports" {
  bucket = aws_s3_bucket.scan_reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.reports.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "scan_reports" {
  bucket                  = aws_s3_bucket.scan_reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "scan_reports" {
  bucket = aws_s3_bucket.scan_reports.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.scan_reports.arn,
        "${aws_s3_bucket.scan_reports.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
