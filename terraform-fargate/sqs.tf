# Queue-based load leveling for the SAST gate.
#
# The API (producer) drops every scan request here and returns immediately, so
# a burst of PRs is absorbed by the queue instead of overloading the scanner.
# Workers (consumers) long-poll and drain at their own pace. A job that keeps
# failing is retried up to maxReceiveCount times, then moved to the DLQ where
# it is preserved for inspection and triggers a CloudWatch alarm (monitoring.tf)

# Dead-letter queue: parks poison messages. Long retention so failures can be
# inspected / replayed.
resource "aws_sqs_queue" "scan_jobs_dlq" {
  name                      = "sast-scan-jobs-dlq"
  message_retention_seconds = 1209600 # 14 days (max)
  sqs_managed_sse_enabled   = true
}

# Main work queue.
resource "aws_sqs_queue" "scan_jobs" {
  name = "sast-scan-jobs"

  # Must exceed a single scan's worst-case time; while a worker holds a message
  # it is invisible to others. If the worker dies, the message reappears after
  # this window and another worker retries it.
  visibility_timeout_seconds = 60

  message_retention_seconds = 86400 # keep undelivered jobs up to 1 day
  receive_wait_time_seconds = 20    # long polling: fewer empty receives, cheaper

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.scan_jobs_dlq.arn
    maxReceiveCount     = 4 # 4 failed attempts, then -> DLQ
  })
}

# Only allow our main queue to redrive into the DLQ.
resource "aws_sqs_queue_redrive_allow_policy" "scan_jobs" {
  queue_url = aws_sqs_queue.scan_jobs_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.scan_jobs.arn]
  })
}
