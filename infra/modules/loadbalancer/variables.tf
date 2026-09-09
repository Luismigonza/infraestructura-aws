variable "name_prefix" {
  description = "Prefijo comun de los nombres."
  type        = string
}

variable "vpc_id" {
  description = "VPC donde vive el balanceador."
  type        = string
}

variable "vpc_cidr" {
  description = "Rango de la VPC. Acota la salida del balanceador hacia las tareas."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets publicas donde se despliega el balanceador. Minimo dos AZ."
  type        = list(string)
}

variable "container_port" {
  description = "Puerto en el que escucha la aplicacion dentro del contenedor."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = <<-EOT
    Ruta que consulta el balanceador para decidir si una tarea esta sana.

    Debe ser un endpoint que NO dependa de la base de datos: ver la
    justificacion completa junto al health_check en main.tf.
  EOT
  type        = string
  default     = "/health"
}
