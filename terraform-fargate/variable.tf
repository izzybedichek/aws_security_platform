# original source: https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166

variable "aws_region" {
  description = "The AWS region things are created in"
}

variable "ec2_task_execution_role_name" {
  description = "ECS task execution role name"
  default     = "myEcsTaskExecutionRole"
}

variable "ecs_auto_scale_role_name" {
  description = "ECS auto scale role name"
  default     = "myEcsAutoScaleRole"
}

variable "az_count" {
  description = "Number of AZs to cover in a given region"
  default     = "2"
}

variable "app_port" {
  description = "Port exposed by the docker image to redirect traffic to"
  default     = 3000

}

variable "app_count" {
  description = "Number of docker containers to run"
  default     = 3
}

variable "health_check_path" {
  default = "/health"
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units to provision (1 vCPU = 1024 CPU units)"
  default     = "1024"
}

variable "fargate_memory" {
  description = "Fargate instance memory to provision (in MiB)"
  default     = "2048"
}

# --- added: previously referenced but never declared ---

variable "scan_reports_bucket_name" {
  description = "Globally-unique S3 bucket name for SAST scan reports"
  type        = string
}

variable "scan_metrics_table_name" {
  description = "DynamoDB table name for scan metrics + job status"
  type        = string
  default     = "sast-scan-metrics"
}

variable "devops_email" {
  description = "Email address subscribed to gate / DLQ SNS alerts"
  type        = string
}

# NOTE: variable "scanner_token" is declared in ssm.tf alongside its resource.

# --- dedicated SQS worker service scaling ---

variable "worker_desired_count" {
  description = "Baseline number of worker tasks draining the scan queue"
  type        = number
  default     = 1
}

variable "worker_min_count" {
  description = "Minimum worker tasks (queue-depth autoscaling floor)"
  type        = number
  default     = 1
}

variable "worker_max_count" {
  description = "Maximum worker tasks (queue-depth autoscaling ceiling)"
  type        = number
  default     = 10
}