# Bootstrap

One-time setup that must exist **before** `.github/workflows/deploy.yml` can run.
Creates: the GitHub Actions OIDC provider, the keyless deploy IAM role, and the
remote-state S3 bucket + DynamoDB lock table.

Uses **local state** (it's what creates the remote backend, so it can't use it).
Run it once, from your laptop, with admin-ish credentials.

## 1. Run it

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform apply
```

If your account already has a GitHub OIDC provider, add
`-var create_oidc_provider=false` so it reuses the existing one.

## 2. Wire up GitHub

```bash
terraform output deploy_role_arn   # -> repo secret  AWS_DEPLOY_ROLE_ARN
```

Then in the repo (Settings → Secrets and variables → Actions):

| Kind     | Name                       | Value                                  |
|----------|----------------------------|----------------------------------------|
| Secret   | `AWS_DEPLOY_ROLE_ARN`      | `terraform output deploy_role_arn`     |
| Secret   | `SCANNER_TOKEN`            | your scanner bearer token              |
| Variable | `AWS_REGION`               | e.g. `us-east-1`                       |
| Variable | `SCAN_REPORTS_BUCKET_NAME` | the reports bucket name                |
| Variable | `DEVOPS_EMAIL`             | alerts recipient                       |

## 3. Switch the main config to remote state

```bash
terraform output backend_block
```

Paste that block into `terraform-fargate/provider.tf` (or a new `backend.tf`),
then run `terraform init -migrate-state` once in `terraform-fargate/` to move
your existing local state into S3. After that, `deploy.yml` can run.
