output "deploy_role_arn" {
  description = "Set this as the GitHub secret AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  value = aws_dynamodb_table.tf_locks.name
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}

# Paste this into terraform-fargate/provider.tf (or a new backend.tf) to switch
# the main config onto remote state.
output "backend_block" {
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.id}"
        key            = "sast/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.tf_locks.name}"
        encrypt        = true
      }
    }
  EOT
}
