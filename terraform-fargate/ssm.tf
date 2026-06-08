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