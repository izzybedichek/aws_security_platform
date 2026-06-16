# Free gateway endpoints so the scanner reaches S3 and DynamoDB over the AWS
# backbone. Associated with the PRIVATE route tables in network.

# tasks reach AWS services either through the NAT gateways (which bill per-GB and route over the internet edge)
# or through VPC endpoints. This file creates Gateway endpoints for S3 and DynamoDB
# and attaches them to the private route tables for Cost, Security, and Resilience

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "sast-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "sast-dynamodb-endpoint" }
}