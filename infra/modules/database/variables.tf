variable "name_prefix" {
  description = "Prefijo comun de los nombres, por ejemplo infra-aws-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC donde viven la base de datos y sus Security Groups."
  type        = string
}

variable "private_subnet_ids" {
  description = <<-EOT
    Subnets privadas donde puede vivir la instancia. Hacen falta al menos dos,
    en zonas distintas: RDS lo exige aunque la instancia no sea Multi-AZ,
    porque asi puede moverla de zona si tiene que reemplazar el hardware.
  EOT
  type        = list(string)
}

variable "engine_version" {
  description = "Version de PostgreSQL. Fijada a proposito: dejarla abierta hace que el plan cambie solo."
  type        = string
  default     = "17.11"
}

variable "instance_class" {
  description = "Tamano de la instancia. db.t3.micro entra en la capa gratuita."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Almacenamiento en GB. La capa gratuita cubre 20."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Nombre de la base de datos inicial."
  type        = string
  default     = "appdb"
}

variable "master_username" {
  description = "Usuario administrador. La contrasena la genera y guarda AWS, no Terraform."
  type        = string
  default     = "appadmin"
}

variable "backup_retention_days" {
  description = <<-EOT
    Dias que se conservan las copias automaticas. El enunciado pide backups
    activados "aunque sea con retencion minima", y 1 es el minimo distinto de
    cero: poner 0 los desactiva por completo.
  EOT
  type        = number
  default     = 1
}
