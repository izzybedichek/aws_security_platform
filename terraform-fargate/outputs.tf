output "alb_hostname" {
  value = "${aws_alb.main.dns_name}:3000"
}

# Consumed by the deploy workflow to push the image and roll out the services.
output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "api_service_name" {
  value = aws_ecs_service.main.name
}

output "worker_service_name" {
  value = aws_ecs_service.worker.name
}
