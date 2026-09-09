# ===========================================================================
# MODULO: BASE DE DATOS
# ===========================================================================
# PostgreSQL gestionado en subnets privadas, sin ninguna ruta desde internet.
#
# Dos ideas gobiernan este modulo:
#
#   1. La contrasena la genera y custodia AWS. Terraform nunca la ve, asi que
#      no puede acabar en el estado ni en un log.
#   2. La base de datos define quien puede entrar sin conocer a sus clientes,
#      mediante un Security Group que actua de "pase de entrada".
# ===========================================================================

# ---------------------------------------------------------------------------
# Donde puede vivir la instancia
# ---------------------------------------------------------------------------
# RDS no acepta una subnet suelta: exige un grupo con al menos dos zonas de
# disponibilidad, incluso si la instancia no es Multi-AZ. Es su forma de poder
# reubicarla si el hardware de una zona falla.
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnets"
  }
}

# ---------------------------------------------------------------------------
# Quien puede entrar
# ---------------------------------------------------------------------------
# EL PASE DE ENTRADA.
#
# Este Security Group no tiene ninguna regla: no permite ni bloquea nada por si
# mismo. Sirve solo de ETIQUETA. Cualquier recurso que lo lleve puesto queda
# autorizado a hablar con la base de datos.
#
# Existe para romper una dependencia circular: la base de datos debe aceptar
# trafico solo desde ECS, pero ECS necesita el endpoint de la base de datos
# para arrancar. Si cada modulo referenciara al otro, Terraform no podria
# ordenar el grafo.
#
# Con este pase, la base de datos declara su politica de acceso sin conocer a
# sus clientes, y en la Fase 4 las tareas de ECS simplemente se lo cuelgan.
resource "aws_security_group" "client" {
  name        = "${var.name_prefix}-db-client"
  description = "Pase de entrada: quien lleve este SG puede conectarse a la base de datos"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-db-client"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Solo acepta PostgreSQL desde quien lleve el SG de cliente"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# La regla clave del proyecto: el origen es un SECURITY GROUP, no un rango de
# IPs. Nunca 0.0.0.0/0, y tampoco el CIDR de la VPC entera (que dejaria entrar
# a cualquier cosa que alguien lance ahi dentro por descuido).
resource "aws_vpc_security_group_ingress_rule" "db_desde_cliente" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.client.id

  from_port   = 5432
  to_port     = 5432
  ip_protocol = "tcp"
  description = "PostgreSQL desde las tareas de la aplicacion"
}

# Sin reglas de salida a proposito. Una base de datos responde a conexiones,
# nunca las inicia. Terraform, a diferencia de la consola de AWS, no anade la
# regla de salida permisiva por defecto si no se la pides.

# ---------------------------------------------------------------------------
# La instancia
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username

  # DECISION DOCUMENTADA: la contrasena la gestiona AWS.
  #
  # La alternativa habitual es `random_password` + el argumento `password`.
  # Funciona, pero deja la contrasena escrita EN TEXTO PLANO dentro del estado
  # de Terraform, que vive en S3. Cualquiera con permiso de lectura sobre ese
  # bucket la puede leer.
  #
  # Con esto, RDS la genera internamente, la guarda en Secrets Manager y
  # Terraform nunca la ve: no pasa por el disco de nadie, no entra al estado, y
  # no puede aparecer en el log de un pipeline. Ademas queda preparada para
  # rotacion automatica.
  manage_master_user_password = true

  allocated_storage = var.allocated_storage

  # gp2 y no gp3: la capa gratuita cubre explicitamente 20 GB de gp2. La
  # diferencia de rendimiento es irrelevante a esta escala.
  storage_type      = "gp2"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  # Sin IP publica. Combinado con las subnets privadas (que no tienen ruta
  # desde el Internet Gateway), la instancia es inalcanzable desde fuera.
  publicly_accessible = false

  # Copias automaticas activadas con la retencion minima. El enunciado lo pide,
  # y ademas RDS exige backup_retention_period > 0 para poder restaurar a un
  # punto en el tiempo.
  backup_retention_period = var.backup_retention_days

  # DECISION DOCUMENTADA: sin Multi-AZ.
  # Multi-AZ duplica el costo manteniendo una replica en espera en otra zona.
  # El enunciado no lo pide, y las subnets ya cubren dos zonas, que es el
  # requisito real. En produccion con datos que importan, esto iria en true.
  multi_az = false

  # DECISION DOCUMENTADA: los tres ajustes de abajo existen para que
  # `terraform destroy` funcione limpio, que es la regla de oro numero 2.
  #
  # En una cuenta de produccion los tres irian al reves: proteccion contra
  # borrado activada y una instantanea final obligatoria. Aqui el ciclo de
  # vida esperado incluye desmontarlo todo, y un destroy que se queda a medias
  # deja una instancia cobrando.
  skip_final_snapshot = true
  deletion_protection = false

  # Los cambios se aplican de inmediato en vez de esperar a la ventana de
  # mantenimiento. Hace falta para la demostracion de la Fase 5: un PR que
  # cambia el tamano de la instancia debe verse aplicado en el momento.
  apply_immediately = true

  # Sin monitorizacion avanzada ni Performance Insights: ambos tienen costo y
  # el proyecto no los necesita.
  monitoring_interval          = 0
  performance_insights_enabled = false

  # Actualizaciones menores automaticas: parches de seguridad de PostgreSQL sin
  # intervencion. Las mayores nunca son automaticas, y asi debe ser.
  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.name_prefix}-postgres"
  }
}
