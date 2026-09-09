output "ecr_repository_url" {
  description = "URL del repositorio de imagenes. Es el destino del docker push."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "Nombre del repositorio de imagenes."
  value       = aws_ecr_repository.app.name
}

output "cluster_name" {
  description = "Nombre del cluster de ECS."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "Nombre del servicio de ECS. Lo usa el pipeline para forzar un redespliegue."
  value       = aws_ecs_service.app.name
}

output "log_group_name" {
  description = "Grupo de CloudWatch donde escribe la aplicacion."
  value       = aws_cloudwatch_log_group.app.name
}

output "task_security_group_id" {
  description = "Security Group de las tareas."
  value       = aws_security_group.tasks.id
}
