output "dns_name" {
  description = "Nombre DNS publico del balanceador. Es la URL de la aplicacion."
  value       = aws_lb.this.dns_name
}

output "url" {
  description = "URL completa de la aplicacion."
  value       = "http://${aws_lb.this.dns_name}"
}

output "target_group_arn" {
  description = "Target group al que el servicio de ECS registra sus tareas."
  value       = aws_lb_target_group.this.arn
}

output "security_group_id" {
  description = "Security Group del balanceador. Las tareas solo aceptan trafico desde el."
  value       = aws_security_group.alb.id
}

output "listener_arn" {
  description = "Listener HTTP. El servicio de ECS debe esperar a que exista antes de arrancar."
  value       = aws_lb_listener.http.arn
}
