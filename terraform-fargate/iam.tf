# Medium article + Claude

# ECS task EXECUTION role (ECS agents can pull images, write logs)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "sast-ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs-task-execution-role-policy-attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS TASK role (scanner code at runtime)
resource "aws_iam_role" "ecs_task_role" {
  name = "sast-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Least-privilege (only ["s3:PutObject", "s3:GetObject"] from s3 scan reports,
# ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"] from kms key reports,
# ["dynamodb:PutItem", "dynamodb:UpdateItem"] from dyanmodb table,
# ["ssm:GetParameter"] from ssm parameter, ["kms:Decrypt"] from any resource
resource "aws_iam_role_policy" "ecs_task_runtime" {
  name = "sast-scanner-runtime"
  role = aws_iam_role.ecs_task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteReports"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.scan_reports.arn}/*"
      },
      {
        Sid      = "ReportKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"]
        Resource = aws_kms_key.reports.arn
      },
      {
        Sid      = "WriteMetrics"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.scan_metrics.arn
      },
      {
        Sid      = "ReadScannerToken"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.scanner_token.arn
      },
      {
        # SecureString params are encrypted with the SSM-managed key; allow
        # decrypt only when the call goes through SSM.
        Sid      = "DecryptSsmParam"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" }
        }
      }
    ]
  })
}


# ECS autoscaling role
data "aws_iam_policy_document" "ecs_auto_scale_role" {
  version = "2012-10-17"
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["application-autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_auto_scale_role" {
  name               = var.ecs_auto_scale_role_name
  assume_role_policy = data.aws_iam_policy_document.ecs_auto_scale_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_auto_scale_role" {
  role       = aws_iam_role.ecs_auto_scale_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
}


