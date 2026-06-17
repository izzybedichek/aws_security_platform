variable "aws_region" {
  description = "AWS region to create the bootstrap resources in"
  type        = string
}

variable "github_owner" {
  description = "GitHub org/user that owns the repo (e.g. izzybedichek)"
  type        = string
}

variable "github_repo" {
  description = "Repository name only (e.g. aws_security_platform)"
  type        = string
}

# Which GitHub Actions identities may assume the deploy role. Defaults allow:
#   - pushes to main (the apply path)
#   - pull requests (the plan path)
# Tighten or remove the pull_request entry if you don't want PRs to assume it.
variable "allowed_subs" {
  description = "OIDC 'sub' patterns permitted to assume the deploy role"
  type        = list(string)
  default = [
    "ref:refs/heads/main",
    "pull_request",
  ]
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name for remote Terraform state"
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "sast-tf-locks"
}

variable "deploy_role_name" {
  description = "Name of the keyless deploy role assumed by GitHub Actions"
  type        = string
  default     = "sast-github-deploy"
}

# If your account already has a GitHub OIDC provider, set this false and the
# module will look it up instead of trying (and failing) to create a second one.
variable "create_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider"
  type        = bool
  default     = true
}
