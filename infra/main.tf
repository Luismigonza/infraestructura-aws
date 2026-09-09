# ===========================================================================
# STACK PRINCIPAL
# ===========================================================================
# Aqui se ensamblan los modulos. Este archivo debe leerse como un indice de la
# arquitectura: quien lo abra tiene que entender la forma del sistema sin
# bajar a los detalles de cada modulo.
#
#   Internet -> ALB (subnets publicas) -> ECS Fargate (privadas) -> RDS (privadas)
#
# Fase 2: modulo network
# Fase 3: modulo database
# Fase 4: modulos loadbalancer y compute
# ===========================================================================

locals {
  # Prefijo comun de todos los nombres. Con esto, ver "infra-aws-dev-alb" en la
  # consola de AWS ya te dice de que proyecto y ambiente es.
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------
module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway
}

# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------
module "database" {
  source = "./modules/database"

  name_prefix        = local.name_prefix
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  engine_version        = var.db_engine_version
  instance_class        = var.db_instance_class
  backup_retention_days = var.db_backup_retention_days
}

# ---------------------------------------------------------------------------
# Balanceador
# ---------------------------------------------------------------------------
module "loadbalancer" {
  source = "./modules/loadbalancer"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  public_subnet_ids = module.network.public_subnet_ids
  container_port    = var.container_port
}

# ---------------------------------------------------------------------------
# Computo
# ---------------------------------------------------------------------------
module "compute" {
  source = "./modules/compute"

  name_prefix        = local.name_prefix
  aws_region         = var.aws_region
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  alb_security_group_id = module.loadbalancer.security_group_id
  target_group_arn      = module.loadbalancer.target_group_arn

  db_client_security_group_id = module.database.client_security_group_id
  db_secret_arn               = module.database.secret_arn
  db_endpoint                 = module.database.endpoint
  db_port                     = module.database.port
  db_name                     = module.database.db_name

  container_port = var.container_port
  image_tag      = var.image_tag
  min_tasks      = var.min_tasks
  max_tasks      = var.max_tasks

  # El servicio de ECS no puede registrar sus tareas si el listener del
  # balanceador todavia no existe. Terraform no deduce esa relacion por si
  # solo, porque el servicio referencia el target group pero no el listener.
  depends_on = [module.loadbalancer]
}
