# ===========================================================================
# MODULO: RED
# ===========================================================================
# Una VPC con subnets publicas y privadas repartidas en varias zonas de
# disponibilidad.
#
# Idea central: una subnet no es "publica" o "privada" por ninguna propiedad
# suya. Lo que la define es a donde apunta su tabla de rutas. Publica = su
# ruta por defecto va al Internet Gateway. Privada = va al NAT Gateway.
# ===========================================================================

# Pregunta a AWS que zonas hay disponibles en esta region. Se consulta en vez
# de escribir "us-east-1a" a mano por dos razones: los nombres cambian entre
# regiones, y AWS asigna las letras de forma distinta en cada cuenta.
data "aws_availability_zones" "disponibles" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.disponibles.names, 0, var.az_count)

  # Cuantos NAT Gateway crear. Ver la justificacion en variables.tf.
  nat_count = var.single_nat_gateway ? 1 : var.az_count

  # -------------------------------------------------------------------------
  # Reparto del rango de direcciones
  # -------------------------------------------------------------------------
  # cidrsubnet(rango, bits_extra, indice) parte un rango en trozos.
  #
  #   cidrsubnet("10.42.0.0/16", 4, 0)   -> 10.42.0.0/20    (4.096 IPs)
  #   cidrsubnet("10.42.0.0/16", 8, 240) -> 10.42.240.0/24  (256 IPs)
  #
  # Privadas /20 porque cada tarea de Fargate consume una IP propia y ahi
  # tambien vive la base de datos. Publicas /24 porque solo alojan el
  # balanceador y el NAT Gateway.
  #
  # Las privadas arrancan al principio del rango (indices 0,1,2) y las
  # publicas al final (240,241,242). Nunca se solapan, y al leer una IP se
  # sabe de un vistazo en que lado esta.
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 240 + i)]
}

# ---------------------------------------------------------------------------
# La VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Ambos hacen falta para que funcionen los nombres DNS internos. Sin ellos,
  # la aplicacion no podria resolver el endpoint de RDS, que AWS entrega como
  # nombre DNS y no como IP.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ---------------------------------------------------------------------------
# Internet Gateway: la puerta bidireccional
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # No se asignan IPs publicas automaticamente. Nada de lo que desplegamos las
  # necesita: el ALB gestiona las suyas y las tareas viven en las privadas.
  # Dejarlo en false evita que algo lanzado aqui por descuido quede expuesto.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-publica-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-privada-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ---------------------------------------------------------------------------
# NAT Gateway: la puerta de una sola direccion
# ---------------------------------------------------------------------------

# Un NAT Gateway necesita una IP publica fija. Una Elastic IP es justo eso:
# una direccion publica reservada a tu cuenta.
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index}"
  }

  # El Internet Gateway debe existir antes de reservar la IP; si no, AWS
  # devuelve un error intermitente segun el orden en que Terraform paralelice.
  depends_on = [aws_internet_gateway.this]
}

# Ojo al detalle: el NAT Gateway vive en una subnet PUBLICA, aunque su trabajo
# sea dar salida a las privadas. Tiene que estar del lado que alcanza el
# Internet Gateway para poder reenviar el trafico hacia afuera.
resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Tablas de rutas: lo que de verdad define publico y privado
# ---------------------------------------------------------------------------

# Una sola tabla para todas las publicas: comparten destino, el IGW.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-publica"
  }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Una tabla por subnet privada. Con un solo NAT todas apuntan al mismo, pero
# separarlas permite cambiar `single_nat_gateway` a false sin reescribir nada:
# cada AZ pasa a usar su propio NAT y el trafico deja de cruzar zonas.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"

    # Con un solo NAT, todas las AZ usan el indice 0. Con uno por AZ, cada una
    # usa el suyo.
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name = "${var.name_prefix}-rt-privada-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# VPC Endpoint de S3: gratis y ahorra dinero
# ---------------------------------------------------------------------------
# Todo byte que sale por el NAT Gateway se cobra a 0,045 USD/GB. Las imagenes
# de contenedor de ECR se guardan por debajo en S3, asi que sin esto cada
# despliegue paga peaje por descargar su propia imagen.
#
# Un endpoint de tipo Gateway es GRATIS (a diferencia de los de tipo
# Interface) y hace que el trafico hacia S3 no salga de la red de AWS: no
# atraviesa el NAT y no genera cargo.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.actual.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Se asocia a las tablas privadas: son las que de otro modo irian por el NAT.
  route_table_ids = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}

data "aws_region" "actual" {}
