# Dedicated SQS worker service.
#
# Same image as the API, but RUN_WORKER is left enabled so these tasks ONLY
# drain the scan queue (the API service runs with RUN_WORKER=false). Keeping
# scans off the API's event loop means a burst of heavy scans never slows down
# request intake. There is no load balancer in front of the workers -- their
# only input is SQS. They scale on queue depth (below).

resource "aws_ecs_task_definition" "worker" {
  family                   = "cb-worker-task"
  task_role_arn            = local.lab_role_arn
  execution_role_arn       = local.lab_role_arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory

  container_definitions = templatefile("${path.module}/templates/ecs/cb_app.json.tpl", {
    app_image      = "${aws_ecr_repository.scanner.repository_url}:latest"
    app_port       = var.app_port
    fargate_cpu    = var.fargate_cpu
    fargate_memory = var.fargate_memory
    aws_region     = var.aws_region
    reports_bucket = aws_s3_bucket.scan_reports.id
    metrics_table  = aws_dynamodb_table.scan_metrics.name
    token_param    = aws_ssm_parameter.scanner_token.name
    scan_queue_url = aws_sqs_queue.scan_jobs.url
    run_worker     = "true" # this service DOES drain the queue
  })
}

resource "aws_ecs_service" "worker" {
  name            = "cb-worker-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.worker_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = aws_subnet.private.*.id
    assign_public_ip = false
  }

  # No load_balancer block: workers are fed by SQS, not the ALB.

  lifecycle {
    # Autoscaling owns desired_count after creation; don't let Terraform
    # fight it back to var.worker_desired_count on every apply.
    ignore_changes = [desired_count]
  }
}

# ---------------------------------------------------------------------------
# Queue-depth autoscaling for the worker service.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "worker" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.worker.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.worker_min_count
  max_capacity       = var.worker_max_count
}

# Scale OUT: add tasks as the backlog grows. step_adjustment bounds are
# relative to the alarm threshold (10), so:
#   10-60 messages  -> +2 tasks
#   60+ messages    -> +4 tasks
resource "aws_appautoscaling_policy" "worker_up" {
  name               = "sast-worker-scale-up"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 30
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 50
      scaling_adjustment          = 2
    }
    step_adjustment {
      metric_interval_lower_bound = 50
      scaling_adjustment          = 4
    }
  }
}

# Scale IN: remove a task when the queue has drained.
resource "aws_appautoscaling_policy" "worker_down" {
  name               = "sast-worker-scale-down"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

# Backlog building up -> scale out.
resource "aws_cloudwatch_metric_alarm" "worker_queue_high" {
  alarm_name          = "sast-worker-queue-high"
  alarm_description   = "Scan queue backlog is growing; add worker tasks"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.scan_jobs.name
  }

  alarm_actions = [aws_appautoscaling_policy.worker_up.arn]
}

# Queue drained -> scale in.
resource "aws_cloudwatch_metric_alarm" "worker_queue_low" {
  alarm_name          = "sast-worker-queue-low"
  alarm_description   = "Scan queue is drained; remove a worker task"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.scan_jobs.name
  }

  alarm_actions = [aws_appautoscaling_policy.worker_down.arn]
}
