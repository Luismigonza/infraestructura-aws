variable "name_prefix" {
  description = "Prefijo comun de los nombres, por ejemplo infra-aws-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "Rango de direcciones de la VPC. La justificacion del valor esta en infra/variables.tf."
  type        = string
}

variable "az_count" {
  description = "Cuantas zonas de disponibilidad usar. Minimo 2."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = <<-EOT
    Si es true, crea UN solo NAT Gateway y lo comparten todas las subnets
    privadas. Si es false, crea uno por zona de disponibilidad.

    DECISION DOCUMENTADA - por defecto true:

    Un NAT Gateway cuesta unos 32 USD/mes y no entra en la capa gratuita. Uno
    por AZ duplica esa cifra a cambio de que la SALIDA a internet siga
    funcionando si una zona se cae.

    Perder el NAT no tumba la aplicacion: el balanceador sigue recibiendo
    trafico y las tareas siguen respondiendo. Lo unico que se rompe es que las
    tareas no pueden INICIAR conexiones salientes (descargar una imagen nueva,
    llamar a una API externa). Pagar el doble por eso en un ambiente que vive
    horas no se justifica.

    En produccion, con trafico real, la respuesta correcta es false.
  EOT
  type        = bool
  default     = true
}
