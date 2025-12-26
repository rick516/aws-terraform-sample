output "alb_url" {
  value       = "http://${aws_lb.app.dns_name}"
  description = "ブラウザで開いて疎通確認するURL"
}

output "ecr_api_repo_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "CI/CDで docker push するときに使う"
}
output "ecr_worker_repo_url" {
  value = aws_ecr_repository.worker.repository_url
}
output "ecr_web_repo_url" {
  value = aws_ecr_repository.web.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_api_name" {
  value = aws_ecs_service.api.name
}
output "ecs_service_worker_name" {
  value = aws_ecs_service.worker.name
}
output "ecs_service_web_name" {
  value = aws_ecs_service.web.name
}
