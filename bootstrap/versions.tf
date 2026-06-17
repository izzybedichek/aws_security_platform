# Bootstrap module: creates the things that must exist BEFORE the main
# terraform-fargate config can run in CI -- the GitHub OIDC provider, the
# keyless deploy role, and the remote-state S3 bucket + DynamoDB lock table.
#
# This module intentionally uses LOCAL state (no backend block): it is what
# creates the remote state backend, so it cannot depend on it. Run it once by
# hand, commit the resulting bootstrap/terraform.tfstate somewhere safe (or
# just keep it locally for a class project).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
