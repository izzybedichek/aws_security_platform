# original source: https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166

resource "aws_ecs_cluster" "main" {
  name = "cb-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "cb-app-task"
  task_role_arn            = aws_iam_role.ecs_task_role.arn
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
    run_worker     = "false" # API service does NOT drain the queue
  })
}

resource "aws_ecs_service" "main" {
  name            = "cb-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id]
    subnets          = aws_subnet.private.*.id
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.app.id
    container_name   = "cb-app"
    container_port   = var.app_port
  }

  depends_on = [aws_alb_listener.front_end, aws_iam_role_policy_attachment.ecs-task-execution-role-policy-attachment]
}

# NOTE: the ecs_task_role and its SQS policy used to live here, duplicating the
# role in iam.tf (a hard Terraform error) and pointing at the old example queue.
# The single source of truth is now aws_iam_role.ecs_task_role in iam.tf, whose
# runtime policy includes the SQS permissions for aws_sqs_queue.scan_jobs.