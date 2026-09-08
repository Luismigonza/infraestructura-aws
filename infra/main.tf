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
