# GitHub Actions OIDC provider. There can be only ONE per account for this URL;
# set create_oidc_provider=false to reuse an existing one.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's well-known intermediate-CA thumbprints. AWS validates the token
  # against its trust store, but the resource still requires this list.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcc",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  # Full sub claims, e.g. "repo:izzybedichek/aws_security_platform:ref:refs/heads/main"
  allowed_subs = [for s in var.allowed_subs : "repo:${var.github_owner}/${var.github_repo}:${s}"]
}
