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
