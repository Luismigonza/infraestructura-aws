# ===========================================================================
# MODULO: BALANCEADOR
# ===========================================================================
# El Application Load Balancer es la unica pieza publica del sistema. Vive en
# las subnets publicas, recibe el trafico de internet, y lo reparte entre las
# tareas que corren en las privadas.
#
# Que este en medio es lo que permite que la aplicacion no tenga IP publica:
# nadie habla con las tareas directamente, todo pasa por aqui.
# ===========================================================================

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Entrada HTTP publica al balanceador"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Este es el UNICO 0.0.0.0/0 de todo el proyecto, y esta justificado: un
# balanceador publico tiene que aceptar peticiones de cualquiera. Compara con
# la base de datos, cuyo origen permitido es un Security Group concreto.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP desde internet"
}

# Salida limitada al rango de la VPC, no a todo internet.
#
# Podria apuntar al Security Group de las tareas, que seria aun mas estricto,
# pero eso crearia una dependencia circular: el SG del balanceador necesitaria
# el de las tareas, y el de las tareas necesita el del balanceador. Acotar al
# CIDR de la VPC rompe el ciclo y sigue impidiendo que el balanceador inicie
# conexiones hacia fuera.
resource "aws_vpc_security_group_egress_rule" "alb_hacia_tareas" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = var.container_port
  to_port           = var.container_port
  ip_protocol       = "tcp"
  description       = "Hacia las tareas de la aplicacion dentro de la VPC"
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  subnets         = var.public_subnet_ids
  security_groups = [aws_security_group.alb.id]

  # Permite que `terraform destroy` funcione sin intervencion manual. En
  # produccion iria en true para que nadie borre por accidente la entrada del
  # sistema.
  enable_deletion_protection = false

  # Descarta cabeceras HTTP malformadas en vez de reenviarlas. Cierra una
  # familia de ataques de "request smuggling", donde un atacante aprovecha que
  # el balanceador y la aplicacion interpretan la misma peticion de forma
  # distinta.
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

# El target group es la lista de destinos a los que repartir. Con Fargate, los
# destinos son DIRECCIONES IP, no instancias: cada tarea recibe su propia IP
# dentro de la subnet privada, y ECS registra y da de baja esas IPs solo.
resource "aws_lb_target_group" "this" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Cuanto espera el balanceador antes de cerrar del todo una tarea que sale de
  # rotacion. El valor por defecto es 300 s, pensado para conexiones largas.
  # Con 30 s los despliegues y el destroy no se eternizan.
  deregistration_delay = 30

  health_check {
    enabled = true
    path    = var.health_check_path

    # La sonda apunta a un endpoint que NO consulta la base de datos. Si lo
    # hiciera, una caida de RDS haria que el balanceador declarara muertas
    # todas las tareas y ECS las reemplazara en bucle: un problema de base de
    # datos se convertiria en una caida total.
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }

  # El target group no se puede borrar mientras un listener lo referencie.
  # Crear el nuevo antes de destruir el viejo evita ese bloqueo al cambiar
  # cualquier atributo que obligue a reemplazarlo.
  lifecycle {
    create_before_destroy = true
  }
}

# DECISION DOCUMENTADA: solo HTTP, sin HTTPS.
#
# AWS Certificate Manager no emite certificados para el nombre DNS
# autogenerado de un balanceador, y este proyecto no tiene dominio propio.
#
# No es una omision, es una limitacion asumida. Con un dominio, el cambio son
# unas veinte lineas: un aws_acm_certificate, su validacion por DNS, un
# listener en el 443 apuntando al mismo target group, y convertir este listener
# del 80 en una redireccion permanente al 443.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
