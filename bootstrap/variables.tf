variable "project_name" {
  description = "Nombre corto del proyecto. Prefija los nombres de los recursos."
  type        = string
  default     = "infra-aws"

  validation {
    # Los nombres de bucket S3 solo admiten minusculas, numeros y guiones.
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Solo minusculas, numeros y guiones (restriccion de nombres de bucket S3)."
  }
}

variable "aws_region" {
  description = "Region de AWS donde vive todo el proyecto."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = <<-EOT
    Perfil del AWS CLI a usar. Dejalo en null para que Terraform tome las
    credenciales del entorno (variables AWS_* o rol IAM), que es como funciona
    dentro de GitHub Actions.
  EOT
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Limite mensual de gasto, en USD, que dispara las alertas."
  type        = string
  default     = "10"
}

variable "budget_alert_email" {
  description = "Correo que recibe las alertas de presupuesto."
  type        = string
}
