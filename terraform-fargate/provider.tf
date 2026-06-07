# original source: https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166

# Specify the provider and access details
provider "aws" {
    region     = var.aws_region
}