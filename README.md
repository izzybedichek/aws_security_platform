# aws_security_platform

A static-analysis (SAST) security gate for CI: when a pull request is opened,
GitHub Actions sends the changed source files to a decoupled scanner running on
AWS (ECS Fargate + SQS + a worker), and the gate **blocks the merge** on any
HIGH-severity finding.

📐 **See [ARCHITECTURE.md](ARCHITECTURE.md)** for the full design: request flow,
a description of every file, ALB-vs-autoscaling and ECS-vs-ECR explainers, and a
rundown of the security / least-privilege / IaC / AWS-services posture.

## Quick start

```bash
# Local (no AWS): run the scanner and smoke-test it
make install && make run      # then, in another shell:
make smoke

# Full AWS deploy (needs live AWS creds, terraform, docker):
export SCANNER_TOKEN=$(openssl rand -hex 24)
make deploy                   # apply infra -> push image -> roll out -> print ALB URL
make destroy                  # tear it all down
```

Run `make help` to see every target.

> The Terraform base was adapted from [this Medium guide](https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166) and substantially extended (SQS worker, OIDC, SSM, KMS, Lambda, monitoring).
