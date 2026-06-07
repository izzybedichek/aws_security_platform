# When the scanner drops a raw JSON report in S3,
# Lambda renders HTML version back into the same bucket
#
# Triggered by S3 ObjectCreated on *.json.

data "archive_file" "report_renderer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/build/report_renderer.zip"
}

resource "aws_iam_role" "report_renderer" {
  name = "sast-report-renderer-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "report_renderer" {
  name = "sast-report-renderer-policy"
  role = aws_iam_role.report_renderer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.scan_reports.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt"]
        Resource = aws_kms_key.reports.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "report_renderer" {
  function_name    = "sast-report-renderer"
  role             = aws_iam_role.report_renderer.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.report_renderer.output_path
  source_code_hash = data.archive_file.report_renderer.output_base64sha256
  timeout          = 30
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report_renderer.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.scan_reports.arn
}

resource "aws_s3_bucket_notification" "scan_reports" {
  bucket = aws_s3_bucket.scan_reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.report_renderer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
