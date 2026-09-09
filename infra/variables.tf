variable "project_name" {
  description = "Nombre corto del proyecto. Prefija el nombre de cada recurso."
  type        = string
  default     = "infra-aws"
}

variable "environment" {
  description = "Ambiente logico (dev, staging, prod). Va en las etiquetas y en los nombres."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Region de AWS donde vive todo el proyecto."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = <<-EOT
    Perfil del AWS CLI. Dejalo en null dentro de CI, donde las credenciales
    llegan por rol IAM y no por archivo de perfil.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = <<-EOT
    Rango de direcciones de la VPC.

    DECISION DOCUMENTADA - por que 10.42.0.0/16 y no otro:

      - 10.0.0.0/16 es el valor por defecto de practicamente todos los
        tutoriales y modulos publicos. Elegirlo garantiza un choque el dia que
        esta VPC tenga que emparejarse con otra red o con una VPN.
      - 172.31.0.0/16 ya esta ocupado: es el rango de la VPC por defecto que
        AWS crea en toda cuenta nueva, incluida esta.
      - 192.168.0.0/16 es el rango tipico de routers domesticos y de oficina.
        Si alguien se conecta por VPN desde su casa, su red local y la VPC
        tendrian el mismo rango y el trafico se perderia.

    10.42.0.0/16 esta dentro del espacio privado de la RFC 1918, deja 65.536
    direcciones (mas que suficientes) y no colisiona con ninguno de los tres.
  EOT
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Cuantas zonas de disponibilidad usar. Minimo 2: si una AZ se cae, el
    sistema sigue en pie. Cada AZ suma un NAT Gateway, y el NAT Gateway es el
    recurso mas caro de esta arquitectura, asi que subir de 2 cuesta dinero.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Entre 2 y 3. Menos de 2 rompe la alta disponibilidad; mas de 3 solo suma costo."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Un solo NAT Gateway compartido (true) o uno por zona de disponibilidad
    (false). La justificacion completa esta en modules/network/variables.tf.

    En una frase: un NAT cuesta ~32 USD/mes, y perderlo no tumba la
    aplicacion, solo impide que las tareas inicien conexiones salientes.
    Pagar el doble por eso en un ambiente efimero no se justifica.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

variable "db_engine_version" {
  description = "Version de PostgreSQL en RDS."
  type        = string
  default     = "17.11"
}

variable "db_instance_class" {
  description = <<-EOT
    Tamano de la instancia de RDS. db.t3.micro entra en la capa gratuita.

    Esta es la variable que se cambia en la Fase 5 para demostrar el flujo
    completo de un Pull Request de infraestructura de punta a punta.
  EOT
  type        = string
  default     = "db.t3.micro"
}

# ---------------------------------------------------------------------------
# Aplicacion
# ---------------------------------------------------------------------------

variable "container_port" {
  description = "Puerto en el que escucha la aplicacion dentro del contenedor."
  type        = number
  default     = 8080
}

variable "image_tag" {
  description = "Etiqueta de la imagen a desplegar. El pipeline la sobreescribe con el SHA del commit."
  type        = string
  default     = "latest"
}

variable "min_tasks" {
  description = "Numero minimo de tareas del servicio."
  type        = number
  default     = 1
}

variable "max_tasks" {
  description = "Numero maximo de tareas del servicio."
  type        = number
  default     = 3
}

variable "db_backup_retention_days" {
  description = <<-EOT
    Dias que RDS conserva las copias de seguridad automaticas.

    Es la variable que se cambia en la demostracion de la Fase 5: subirla es un
    cambio de infraestructura realista, se aplica en caliente sin cortar el
    servicio, y no cuesta dinero a este volumen de datos.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "Entre 1 y 35. Cero desactivaria las copias, y el enunciado las exige."
  }
}
