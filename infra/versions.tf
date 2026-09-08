terraform {
  required_version = ">= 1.6.0"

  # Configuracion parcial: los valores llegan de backend.hcl, que genera el
  # stack de bootstrap. Ver bootstrap/main.tf para el porque.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Stack       = "infra"
    }
  }
}
