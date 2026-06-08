# alarm if the security gate goes down
# watches the ALB target group's healthy-host count
# if no scanner target is healthy or the metric stops reporting,
# the alarm fires and SNS emails the DevOps address.
#
# This is distinct from the CPU autoscaling alarms already in auto_scaling.tf.

resource "aws_sns_topic" "gate_alerts" {
  name = "sast-gate-alerts"
}

resource "aws_sns_topic_subscription" "devops_email" {
  topic_arn = aws_sns_topic.gate_alerts.arn
  protocol  = "email"
  endpoint  = var.devops_email
  # NOTE: AWS sends a confirmation email; the subscription is pending until
  # the DevOps recipient clicks the link.
}

resource "aws_cloudwatch_metric_alarm" "scanner_gate_down" {
  alarm_name        = "sast-gate-down"
  alarm_description = "No healthy SAST scanner targets registered behind the ALB"

  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  statistic   = "Minimum"
  period      = 60

  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    TargetGroup  = aws_alb_target_group.app.arn_suffix
    LoadBalancer = aws_alb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.gate_alerts.arn]
  ok_actions    = [aws_sns_topic.gate_alerts.arn]
}

# Fires the moment a scan job lands in the DLQ (failed 4x). This is how a
# "never lost" request surfaces to a human: the message is preserved in the
# DLQ and DevOps is emailed to investigate / replay it.
resource "aws_cloudwatch_metric_alarm" "scan_dlq_not_empty" {
  alarm_name        = "sast-scan-dlq-not-empty"
  alarm_description = "A scan job failed repeatedly and was moved to the dead-letter queue"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  statistic   = "Maximum"
  period      = 60

  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.scan_jobs_dlq.name
  }

  alarm_actions = [aws_sns_topic.gate_alerts.arn]
  ok_actions    = [aws_sns_topic.gate_alerts.arn]
}
