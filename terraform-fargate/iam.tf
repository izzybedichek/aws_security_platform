# AWS Academy Learner Lab blocks iam:CreateRole, so we cannot create custom
# roles. Every service instead uses the pre-provisioned LabRole, which already
# has broad permissions and a trust policy covering ecs-tasks, lambda, etc.
#
# (In a normal AWS account you'd restore the least-privilege roles that were
# here before -- ecs_task_role with scoped S3/DynamoDB/SQS/SSM/KMS access, a
# separate execution role, autoscale role, and lambda role. See git history.)

data "aws_caller_identity" "current" {}

locals {
  lab_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
}
