#stores the shared bearer token as an aws_ssm_parameter of type SecureString
# SSM encrypts it at rest with KMS. The value comes from var.scanner_token,
# passed via TF_VAR_scanner_token and never commit.
# At runtime the container calls GetParameter ... WithDecryption=true to load it
# the secret lives in exactly one managed place
# the only thing baked into the task is the parameter name (/sast/scanner-token), never the value
# The same token is shared with callers (the GitHub Actions secret)

variable "scanner_token" {
  description = "Shared bearer token for the SAST scanner"
  type        = string
  sensitive   = true
}

resource "aws_ssm_parameter" "scanner_token" {
  name  = "/sast/scanner-token"
  type  = "SecureString" # matches WithDecryption:true in server.js
  value = var.scanner_token
}