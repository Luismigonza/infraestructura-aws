# ===========================================================================
# MODULO: COMPUTO
# ===========================================================================
# El registro de imagenes, el cluster de ECS, la definicion de la tarea, el
# servicio que la mantiene viva y el auto scaling.
#
# DECISION DOCUMENTADA: Fargate y no EC2.
#
# Con EC2 alquilas maquinas: pagas por ellas esten ocupadas o no, y te toca
# parchear el sistema operativo, vigilar el disco y gestionar el agente de ECS.
# Con Fargate declaras cuanta CPU y memoria necesita el contenedor y AWS pone
# el resto: no hay servidor que administrar y solo se paga mientras la tarea
# corre.
#
# EC2 gana cuando hay carga constante y alta (sale mas barato por hora
# reservada) o cuando hace falta algo que Fargate no ofrece, como GPUs o un
# kernel concreto. Nada de eso aplica aqui.
# ===========================================================================

# ---------------------------------------------------------------------------
# Registro de imagenes
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name = var.name_prefix

  # Analisis de vulnerabilidades gratuito en cada push. No cuesta nada y avisa
  # si la imagen base arrastra un CVE conocido.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Sin esto, `terraform destroy` falla si el repositorio contiene imagenes, y
  # despues del primer despliegue siempre las contiene. Regla de oro numero 2.
  force_delete = true

  tags = {
    Name = var.name_prefix
  }
}

# Sin esto, cada despliegue deja una imagen huerfana acumulandose para siempre.
# ECR cobra por GB almacenado.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Conservar solo las 10 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Registro de actividad
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${var.name_prefix}"

  # Los logs se cobran por GB almacenado y se guardan para siempre por defecto.
  # Una semana basta para depurar un despliegue y evita una factura que crece
  # sola sin que nadie la mire.
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.name_prefix}-logs"
  }
}

# ---------------------------------------------------------------------------
# Identidades
# ---------------------------------------------------------------------------
# ECS usa DOS roles distintos, y confundirlos es un error clasico:
#
#   - El rol de EJECUCION lo usa la infraestructura de ECS ANTES de que tu
#     codigo arranque: descargar la imagen, crear el grupo de logs, leer los
#     secretos que hay que inyectar.
#   - El rol de TAREA lo usa TU CODIGO una vez corriendo, para llamar a otras
#     APIs de AWS.
#
# Separarlos significa que si alguien compromete la aplicacion, no hereda el
# permiso de leer secretos: ese permiso lo tuvo el agente de ECS, no el proceso.

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${var.name_prefix}-ecs-execution"
  }
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Permiso para leer EL secreto de la base de datos, no todos los secretos de la
# cuenta. El `Resource` apunta a un ARN concreto: es la diferencia entre un
# permiso acotado y una llave maestra.
data "aws_iam_policy_document" "leer_secreto" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  # El secreto lo cifra la clave gestionada de AWS para Secrets Manager. Sin
  # permiso para descifrar con ella, la lectura falla aunque el permiso de
  # arriba este concedido.
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secretos" {
  name   = "leer-secreto-de-base-de-datos"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.leer_secreto.json
}

# El rol de la tarea no lleva ningun permiso: la aplicacion solo habla con
# PostgreSQL, y para eso no hace falta ninguna API de AWS. Se crea igualmente
# porque el dia que la aplicacion necesite leer de S3 o publicar en una cola,
# el sitio donde anadirlo ya existe y esta separado del otro rol.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = {
    Name = "${var.name_prefix}-ecs-task"
  }
}

# ---------------------------------------------------------------------------
# Red de las tareas
# ---------------------------------------------------------------------------

resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Tareas de la aplicacion: solo aceptan trafico del balanceador"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-tasks"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Origen: el Security Group del balanceador. Nadie mas puede hablar con las
# tareas, ni siquiera otro recurso dentro de la misma subnet.
resource "aws_vpc_security_group_ingress_rule" "desde_alb" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = var.alb_security_group_id

  from_port   = var.container_port
  to_port     = var.container_port
  ip_protocol = "tcp"
  description = "HTTP desde el balanceador"
}

# Salida abierta: las tareas necesitan descargar su imagen de ECR, escribir
# logs en CloudWatch y leer el secreto. Todo eso sale por el NAT Gateway, y
# ninguno de esos destinos tiene un rango de IPs fijo que se pueda acotar.
resource "aws_vpc_security_group_egress_rule" "salida" {
  security_group_id = aws_security_group.tasks.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Salida hacia ECR, CloudWatch Logs y Secrets Manager"
}

# ---------------------------------------------------------------------------
# Cluster y tarea
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "disabled" # Container Insights tiene costo por metrica.
  }

  tags = {
    Name = var.name_prefix
  }
}

resource "aws_ecs_task_definition" "app" {
  family = var.name_prefix

  # awsvpc: cada tarea recibe su propia interfaz de red y su propia IP dentro
  # de la subnet privada. Es lo que permite aplicarle Security Groups como si
  # fuera una maquina, y lo que exige Fargate.
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  # La combinacion mas pequena que admite Fargate. 0,25 vCPU y 512 MB bastan de
  # sobra para esta aplicacion.
  cpu    = var.task_cpu
  memory = var.task_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = var.name_prefix
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    # Configuracion no sensible: viaja en claro sin problema.
    environment = [
      { name = "PORT", value = tostring(var.container_port) },
      { name = "DB_HOST", value = var.db_endpoint },
      { name = "DB_PORT", value = tostring(var.db_port) },
      { name = "DB_NAME", value = var.db_name },
    ]

    # Configuracion sensible: NO viaja aqui. Solo el ARN del secreto.
    #
    # El sufijo `:username::` le dice a ECS que extraiga esa clave del JSON que
    # guarda Secrets Manager. El agente de ECS lee el secreto con el rol de
    # ejecucion y lo inyecta como variable de entorno en el arranque.
    #
    # Resultado: la contrasena no esta en el repositorio, ni en el estado de
    # Terraform, ni en la definicion de la tarea. Solo en Secrets Manager y en
    # la memoria del contenedor.
    secrets = [
      { name = "DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])

  tags = {
    Name = var.name_prefix
  }
}

# ---------------------------------------------------------------------------
# Servicio
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = var.name_prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.min_tasks
  launch_type     = "FARGATE"

  network_configuration {
    subnets = var.private_subnet_ids

    # Dos Security Groups a la vez:
    #   - el propio, que permite la entrada desde el balanceador
    #   - el "pase de entrada" que exporta el modulo de base de datos
    # Una interfaz de red puede llevar varios, y los permisos se suman.
    security_groups = [aws_security_group.tasks.id, var.db_client_security_group_id]

    # Sin IP publica. Las tareas salen a internet por el NAT Gateway y no son
    # alcanzables desde fuera.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = var.name_prefix
    container_port   = var.container_port
  }

  # Cuanto espera ECS antes de creer al health check del balanceador. Sin este
  # margen, una tarea que tarda en arrancar seria declarada muerta y
  # reemplazada antes de haber llegado a escuchar.
  health_check_grace_period_seconds = 60

  # Si un despliegue nuevo no consigue estabilizarse, ECS vuelve solo a la
  # version anterior en vez de dejar el servicio caido. Es la red de seguridad
  # que hace tolerable el `apply` automatico de la Fase 5.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # El numero de tareas lo gobierna el auto scaling, no Terraform. Sin esto,
    # cada `apply` devolveria el servicio al minimo, deshaciendo un escalado
    # que se hizo porque hacia falta.
    ignore_changes = [desired_count]
  }

  tags = {
    Name = var.name_prefix
  }
}

# ---------------------------------------------------------------------------
# Auto scaling
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.min_tasks
  max_capacity = var.max_tasks
}

# Target tracking: se declara el objetivo ("la CPU media al 60 %") y AWS
# calcula solo cuando anadir o quitar tareas. La alternativa, step scaling,
# obliga a definir a mano cada umbral y cuanto escalar en cada uno.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name_prefix}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = var.cpu_target_percent

    # Escalar hacia arriba es barato y rapido; hacia abajo conviene ser
    # prudente para no quedarse corto ante un repunte. De ahi la asimetria.
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
