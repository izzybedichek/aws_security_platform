# Hamza -- feel free to change/improve, I just wanted to see what everything
# looked like altogether

# a customer-managed key with enable_key_rotation = true
# #reports are encrypted with a key you control and that rotates annually.
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

  # Allow `terraform destroy` to empty + delete the bucket even when it holds
  # report objects (and old versions). Convenient for tearing down between uses.
  force_destroy = true
}

# keeps old versions, so a report can't be silently overwritten/lost (audit trail)
resource "aws_s3_bucket_versioning" "scan_reports" {
  bucket = aws_s3_bucket.scan_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

# orces every object to be encrypted with that KMS key. bucket_key_enabled = true is a cost optimization
# uses an S3 bucket-level data key
# so you aren't billed for a KMS call on every single PutObject.
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

# all four flags true, nothing in this bucket can ever become public
resource "aws_s3_bucket_public_access_block" "scan_reports" {
  bucket                  = aws_s3_bucket.scan_reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# denies any request where aws:SecureTransport = false
# i.e. blocks plain-HTTP access so reports only move over TLS.
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
