# The keyless role GitHub Actions assumes via OIDC. Its trust policy is scoped
# to THIS repo and the specific refs in var.allowed_subs, so no other repo (and
# no fork) can assume it.

data "aws_iam_policy_document" "deploy_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.allowed_subs
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.deploy_role_name
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume.json
  max_session_duration = 3600
}

# Permissions the deploy role needs to manage the terraform-fargate stack.
#
# NOTE: scoped to the SERVICES this project uses (not AdministratorAccess), but
# broad WITHIN each service because Terraform creates resources whose ARNs don't
# exist yet, so they can't be pre-listed. For production, tighten each statement
# with resource ARNs / conditions or generate the policy from a plan.
data "aws_iam_policy_document" "deploy_permissions" {
  # VPC / networking (network.tf, security.tf, endpoints.tf)
  statement {
    sid    = "Networking"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:AllocateAddress", "ec2:ReleaseAddress",
      "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:CreateRoute", "ec2:DeleteRoute",
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # ECS, ECR, ALB, autoscaling, Lambda (ecs.tf, worker.tf, ecr.tf, alb.tf, etc.)
  statement {
    sid    = "ComputeAndDelivery"
    effect = "Allow"
    actions = [
      "ecs:*",
      "ecr:*",
      "elasticloadbalancing:*",
      "application-autoscaling:*",
      "lambda:*",
    ]
    resources = ["*"]
  }

  # Data + messaging + state backend (s3.tf, dynamodb.tf, sqs.tf, monitoring.tf,
  # plus the remote state bucket/lock table this role reads & writes).
  statement {
    sid    = "DataAndMessaging"
    effect = "Allow"
    actions = [
      "s3:*",
      "dynamodb:*",
      "sqs:*",
      "sns:*",
    ]
    resources = ["*"]
  }

  # Observability + config (logs.tf, monitoring.tf, ssm.tf, KMS in s3.tf)
  statement {
    sid    = "ObservabilityAndConfig"
    effect = "Allow"
    actions = [
      "logs:*",
      "cloudwatch:*",
      "ssm:*",
      "kms:*",
    ]
    resources = ["*"]
  }

  # IAM: create/manage the task, execution, autoscaling and lambda roles +
  # their policies. PassRole is required so ECS/Lambda can use those roles.
  statement {
    sid    = "IamForServiceRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
      "iam:PassRole",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.deploy_role_name}-permissions"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}
