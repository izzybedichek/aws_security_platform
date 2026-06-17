# Build & push after `terraform apply` (see ecr_repository_url output):
#   aws ecr get-login-password --region <region> \
#     | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
#   docker build -t sast-scanner ../sast/backend
#   docker tag sast-scanner:latest <repo_url>:latest
#   docker push <repo_url>:latest

resource "aws_ecr_repository" "scanner" {
  name                 = "sast-scanner"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.scanner.repository_url
}
