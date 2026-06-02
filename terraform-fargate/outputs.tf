# original source: https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166

output "alb_hostname" {
  value = "${aws_alb.main.dns_name}:3000"
}STEP 13: