# Los outputs son el contrato del stack con quien lo usa. La URL de la
# aplicacion vivira aqui: el paso 4 de la Definition of Done dice que quien
# clone el repo debe poder entrar a la app "por la URL que Terraform le
# devuelve como output".

output "region" {
  description = "Region donde se desplego el ambiente."
  value       = var.aws_region
}

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID de la VPC creada."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Subnets publicas (balanceador)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Subnets privadas (aplicacion y base de datos)."
  value       = module.network.private_subnet_ids
}

output "availability_zones" {
  description = "Zonas de disponibilidad en uso."
  value       = module.network.availability_zones
}

output "nat_public_ips" {
  description = "IPs de salida de las subnets privadas."
  value       = module.network.nat_public_ips
}

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

output "db_endpoint" {
  description = "Endpoint de PostgreSQL. Solo resuelve dentro de la VPC."
  value       = module.database.endpoint
}

output "db_secret_arn" {
  description = "Secreto de Secrets Manager con las credenciales gestionadas por AWS."
  value       = module.database.secret_arn
}

output "db_client_security_group_id" {
  description = "Security Group que autoriza a conectarse a la base de datos."
  value       = module.database.client_security_group_id
}

# ---------------------------------------------------------------------------
# Aplicacion
# ---------------------------------------------------------------------------

output "app_url" {
  description = "URL publica de la aplicacion. Este es el entregable visible del proyecto."
  value       = module.loadbalancer.url
}

output "ecr_repository_url" {
  description = "Destino del docker push."
  value       = module.compute.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "Cluster de ECS."
  value       = module.compute.cluster_name
}

output "ecs_service_name" {
  description = "Servicio de ECS."
  value       = module.compute.service_name
}

output "log_group_name" {
  description = "Grupo de logs de la aplicacion en CloudWatch."
  value       = module.compute.log_group_name
}
