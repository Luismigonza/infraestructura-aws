# Versiones fijadas a proposito.
#
# `required_version` evita que alguien con un Terraform muy viejo (o de una
# generacion futura con cambios incompatibles) aplique este codigo y produzca
# un resultado distinto al documentado.
#
# `~> 6.0` en el proveedor de AWS significa "cualquier 6.x, pero nunca 7.0".
# Los cambios de version mayor en el proveedor rompen recursos; los menores no.

terraform {
  required_version = ">= 1.6.0"

  # Backend en "configuracion parcial": aqui solo se declara el TIPO. Los
  # valores concretos (que bucket, que tabla) llegan al hacer
  # `terraform init -backend-config=backend.hcl`, porque dependen del ID de la
  # cuenta de AWS y no pueden escribirse fijos en un repositorio compartido.
  #
  # Este bloque se anadio DESPUES del primer apply, a proposito: el bucket
  # tenia que existir antes de poder guardar el estado dentro de el.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Etiquetas aplicadas automaticamente a todo recurso que las soporte.
  # Sirven para dos cosas: filtrar el gasto por proyecto en Cost Explorer, y
  # poder responder "que es esto y quien lo creo" al ver un recurso suelto.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
      Stack     = "bootstrap"
    }
  }
}
