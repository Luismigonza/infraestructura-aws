output "endpoint" {
  description = "Nombre DNS de la instancia. Solo resuelve dentro de la VPC."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Puerto de PostgreSQL."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Nombre de la base de datos inicial."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Usuario administrador."
  value       = aws_db_instance.this.username
}

output "secret_arn" {
  description = <<-EOT
    ARN del secreto de Secrets Manager donde AWS guarda la credencial.

    El contenido es un JSON con las claves `username` y `password`. ECS sabe
    extraer una clave concreta anadiendo `:password::` al final del ARN, asi
    que la contrasena llega al contenedor como variable de entorno sin pasar
    nunca por Terraform ni por el repositorio.
  EOT
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "client_security_group_id" {
  description = <<-EOT
    El "pase de entrada". Cualquier recurso que lleve puesto este Security
    Group queda autorizado a conectarse a la base de datos.
  EOT
  value       = aws_security_group.client.id
}

output "security_group_id" {
  description = "Security Group de la propia instancia."
  value       = aws_security_group.db.id
}
