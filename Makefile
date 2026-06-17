# =============================================================================
# SAST Security Platform — launch & deploy
#
#   Local (no AWS):   make install && make run        (or: make docker)
#   Full AWS deploy:  export SCANNER_TOKEN=... && make deploy
#
# Requirements for deploy: valid AWS credentials in your shell (for AWS Academy,
# paste the Learner Lab "AWS CLI" creds into ~/.aws/credentials), terraform,
# docker, and the aws CLI. Run `make check-aws` to confirm creds are live.
# =============================================================================

SHELL       := /bin/bash
TF_DIR      := terraform-fargate
BACKEND_DIR := sast/backend
AWS_REGION  ?= us-east-1
PLATFORM    ?= linux/amd64        # Fargate runs amd64; Apple Silicon defaults to arm64
IMAGE_LOCAL ?= sast-scanner
SCANNER_TOKEN ?=

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
# Local development (no AWS needed)
# -----------------------------------------------------------------------------
.PHONY: install
install: ## Install backend Node dependencies
	cd $(BACKEND_DIR) && npm install

.PHONY: run
run: ## Run the scanner locally with `node` (token=devtoken, worker off)
	cd $(BACKEND_DIR) && SCANNER_TOKEN=devtoken RUN_WORKER=false node server.js

.PHONY: docker
docker: ## Build + run the scanner container locally on :3000 (no AWS)
	docker build -t $(IMAGE_LOCAL) $(BACKEND_DIR)
	docker run --rm -p 3000:3000 -e SCANNER_TOKEN=devtoken -e RUN_WORKER=false $(IMAGE_LOCAL)

.PHONY: smoke
smoke: ## Hit a locally-running scanner (/health + a demo /scan/code)
	curl -s localhost:3000/health | sed 's/^/health: /'; echo
	curl -s -X POST localhost:3000/scan/code \
	  -H "Authorization: Bearer devtoken" -H "Content-Type: application/json" \
	  -d '{"code":"const pw=\"hunter2\"; eval(userInput)","filename":"t.js"}'; echo

# -----------------------------------------------------------------------------
# AWS deploy  (local state in $(TF_DIR); no remote backend / no CI required)
# -----------------------------------------------------------------------------
.PHONY: check-aws
check-aws: ## Verify AWS credentials are live
	aws sts get-caller-identity

.PHONY: guard-token
guard-token:
	@if [ -z "$(SCANNER_TOKEN)" ]; then \
	  echo "ERROR: set the shared bearer token first, e.g.  export SCANNER_TOKEN=$$(openssl rand -hex 24)"; \
	  echo "       (this becomes the SSM param /sast/scanner-token and the Bearer token callers must send)"; \
	  exit 1; \
	fi

.PHONY: tf-init
tf-init: ## terraform init
	cd $(TF_DIR) && terraform init -input=false

.PHONY: tf-plan
tf-plan: guard-token tf-init ## Preview infra changes
	cd $(TF_DIR) && TF_VAR_scanner_token='$(SCANNER_TOKEN)' terraform plan -input=false

.PHONY: deploy-infra
deploy-infra: guard-token tf-init ## terraform apply (creates all AWS resources)
	cd $(TF_DIR) && TF_VAR_scanner_token='$(SCANNER_TOKEN)' terraform apply -auto-approve -input=false

.PHONY: ecr-login
ecr-login: ## Log docker into this account's ECR registry
	cd $(TF_DIR) && ECR=$$(terraform output -raw ecr_repository_url) && \
	  aws ecr get-login-password --region $(AWS_REGION) \
	    | docker login --username AWS --password-stdin "$${ECR%%/*}"

.PHONY: image
image: ecr-login ## Build (amd64) + push the scanner image to ECR
	cd $(TF_DIR) && ECR=$$(terraform output -raw ecr_repository_url) && \
	  docker build --platform $(PLATFORM) -t "$$ECR:latest" ../$(BACKEND_DIR) && \
	  docker push "$$ECR:latest"

.PHONY: rollout
rollout: ## Force ECS to pull the new image (API + worker services)
	cd $(TF_DIR) && \
	  CL=$$(terraform output -raw cluster_name) && \
	  API=$$(terraform output -raw api_service_name) && \
	  WK=$$(terraform output -raw worker_service_name) && \
	  aws ecs update-service --cluster "$$CL" --service "$$API" --force-new-deployment --region $(AWS_REGION) >/dev/null && \
	  aws ecs update-service --cluster "$$CL" --service "$$WK"  --force-new-deployment --region $(AWS_REGION) >/dev/null && \
	  echo "rolled out: $$API + $$WK"

.PHONY: deploy
deploy: deploy-infra image rollout url ## FULL deploy: apply infra -> push image -> roll out -> print URL

.PHONY: url
url: ## Print the scanner ALB URL and how to call it
	@cd $(TF_DIR) && \
	  echo "Scanner URL : http://$$(terraform output -raw alb_hostname)" && \
	  echo "Health      : curl http://$$(terraform output -raw alb_hostname)/health" && \
	  echo "Auth header : Authorization: Bearer <your SCANNER_TOKEN>"

.PHONY: destroy
destroy: guard-token ## Tear down all AWS resources
	cd $(TF_DIR) && TF_VAR_scanner_token='$(SCANNER_TOKEN)' terraform destroy -input=false

# -----------------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@echo "SAST platform — make targets:"; echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
