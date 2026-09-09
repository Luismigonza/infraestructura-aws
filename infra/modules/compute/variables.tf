variable "name_prefix" {
  description = "Prefijo comun de los nombres."
  type        = string
}

variable "aws_region" {
  description = "Region. La necesitan el driver de logs y la condicion de KMS."
  type        = string
}

variable "vpc_id" {
  description = "VPC donde viven las tareas."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas donde corren las tareas."
  type        = list(string)
}

# --- Entradas que vienen del modulo de balanceador ---

variable "alb_security_group_id" {
  description = "Security Group del balanceador. Unico origen permitido hacia las tareas."
  type        = string
}

variable "target_group_arn" {
  description = "Target group donde el servicio registra las IPs de sus tareas."
  type        = string
}

# --- Entradas que vienen del modulo de base de datos ---

variable "db_client_security_group_id" {
  description = "El pase de entrada a la base de datos. Se cuelga a las tareas."
  type        = string
}

variable "db_secret_arn" {
  description = "Secreto de Secrets Manager con las credenciales. Solo viaja el ARN."
  type        = string
}

variable "db_endpoint" {
  description = "Nombre DNS de la base de datos."
  type        = string
}

variable "db_port" {
  description = "Puerto de la base de datos."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Nombre de la base de datos inicial."
  type        = string
}

# --- Ajustes del contenedor ---

variable "container_port" {
  description = "Puerto en el que escucha la aplicacion."
  type        = number
  default     = 8080
}

variable "image_tag" {
  description = <<-EOT
    Etiqueta de la imagen a desplegar.

    `latest` sirve para la primera puesta en marcha manual, pero en el pipeline
    se sobreescribe con el SHA del commit. Desplegar por SHA hace que cada
    despliegue apunte a un artefacto inmutable: se sabe exactamente que codigo
    esta corriendo y se puede volver atras a una version concreta.
  EOT
  type        = string
  default     = "latest"
}

variable "task_cpu" {
  description = "Unidades de CPU. 256 = 0,25 vCPU, el minimo de Fargate."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Memoria en MB. 512 es el minimo admitido con 256 de CPU."
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "Dias que se conservan los logs. Por defecto CloudWatch los guarda para siempre y cobra por ello."
  type        = number
  default     = 7
}

# --- Auto scaling ---

variable "min_tasks" {
  description = "Numero minimo de tareas."
  type        = number
  default     = 1
}

variable "max_tasks" {
  description = "Numero maximo de tareas."
  type        = number
  default     = 3
}

variable "cpu_target_percent" {
  description = "Uso medio de CPU que el auto scaling intenta mantener."
  type        = number
  default     = 60
}
