# Los outputs son el contrato del modulo. Todo lo que otro modulo necesite
# saber de la red pasa por aqui; nadie deberia alcanzar los recursos de este
# modulo por dentro.

output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Rango de la VPC. Lo usan los Security Groups para permitir trafico interno."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs de las subnets publicas. Aqui va el balanceador."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas. Aqui van las tareas de ECS y la base de datos."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Zonas de disponibilidad efectivamente usadas."
  value       = local.azs
}

output "nat_public_ips" {
  description = <<-EOT
    IPs publicas desde las que sale el trafico de las subnets privadas.
    Utiles cuando un servicio externo pide una lista de IPs autorizadas.
  EOT
  value       = aws_eip.nat[*].public_ip
}
