# ===========================================================================
# STACK DE BOOTSTRAP
# ===========================================================================
# Crea lo que tiene que existir ANTES de poder gestionar nada mas con
# Terraform: el almacen del estado remoto, su cerrojo, y la alerta de gasto.
#
# Este stack se aplica una sola vez, a mano, y casi nunca se vuelve a tocar.
# ===========================================================================

# Pregunta a AWS "quien soy" usando las credenciales activas. Devuelve el ID de
# la cuenta, que usamos para construir un nombre de bucket unico sin
# escribirlo a mano: asi este mismo codigo funciona en la cuenta de cualquiera.
data "aws_caller_identity" "current" {}

locals {
  # Los nombres de bucket S3 son unicos GLOBALMENTE, no por cuenta: compites
  # con todos los usuarios de AWS del planeta. Colgarle el ID de la cuenta
  # (que es unico y no es secreto) resuelve el problema de forma determinista.
  state_bucket_name = "tfstate-${var.project_name}-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "tflock-${var.project_name}"

  # El backend se autentica por su cuenta, aparte del provider: se inicializa
  # antes de que las variables existan, asi que no puede leer var.aws_profile.
  # Sin esta linea, `terraform init` en una maquina sin AWS_PROFILE en el
  # entorno falla con "No valid credential sources found".
  #
  # En CI no hay perfil (las credenciales llegan por rol IAM), y ahi
  # var.aws_profile es null: la linea simplemente no se emite.
  backend_profile_line = var.aws_profile != null ? "profile        = \"${var.aws_profile}\"" : ""
}

# ---------------------------------------------------------------------------
# S3: donde vive el estado de Terraform
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  # DECISION DOCUMENTADA: force_destroy = true.
  #
  # Sin esto, `terraform destroy` falla si el bucket tiene objetos, y con
  # versionado activado siempre los tiene. En una cuenta de produccion se deja
  # en false y ademas se pone `prevent_destroy`, porque borrar el estado por
  # accidente es catastrofico.
  #
  # Aqui lo dejamos en true a proposito: el ciclo de vida esperado de este
  # proyecto incluye desmontarlo por completo, y la regla de oro numero 2 dice
  # que el destroy tiene que funcionar limpio de verdad. La red de seguridad
  # que perdemos la compensa el versionado de abajo.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Cada `apply` sobrescribe el archivo de estado. Con versionado, la version
  # anterior no se pierde: si un apply corrompe el estado, se restaura la
  # version previa desde la consola de S3. Es el equivalente a un "undo".
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # El estado guarda en texto plano cosas que en el codigo estan protegidas
  # (por ejemplo, la contrasena que RDS genera). Cifrar en reposo es el minimo.
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  # Los cuatro candados. Bloquean cualquier intento de hacer el bucket publico,
  # incluso si alguien despues aplica por error una politica permisiva.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Rechaza cualquier peticion que no venga cifrada por TLS. Sin esto, alguien
# podria leer el estado por HTTP plano desde dentro de la red de AWS.
resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenegarTraficoSinTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.tfstate.arn,
        "${aws_s3_bucket.tfstate.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  # El bloqueo de acceso publico debe aplicarse antes que la politica, o AWS
  # puede rechazarla por considerarla una politica que expone el bucket.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# ---------------------------------------------------------------------------
# DynamoDB: el cerrojo del estado
# ---------------------------------------------------------------------------
# DECISION DOCUMENTADA: doble mecanismo de bloqueo.
#
# Sin cerrojo, dos `apply` simultaneos (tu portatil y el pipeline, por ejemplo)
# parten de fotos distintas de la realidad y el ultimo en escribir pisa lo que
# hizo el otro. El resultado es un estado que no corresponde con AWS.
#
# Desde Terraform 1.10 el backend S3 sabe bloquear por si solo (`use_lockfile`),
# y `dynamodb_table` quedo marcado como obsoleto. Mantenemos DynamoDB porque es
# un requisito explicito del enunciado, y activamos ademas el bloqueo nativo de
# S3 porque DynamoDB va camino de desaparecer: el dia que lo eliminen, se borra
# una linea de backend.hcl y el cerrojo sigue funcionando.
#
# Consecuencia visible: `terraform init` imprime un aviso de parametro obsoleto.
# Es esperado, no un error.

resource "aws_dynamodb_table" "tflock" {
  name = local.lock_table_name

  # PAY_PER_REQUEST en vez de capacidad reservada: pagas por operacion. Esta
  # tabla recibe un punado de escrituras al dia, asi que el costo real es
  # practicamente cero. Con capacidad reservada pagarias por horas ociosas.
  billing_mode = "PAY_PER_REQUEST"

  # El backend S3 de Terraform exige que la clave primaria se llame LockID.
  # No es una eleccion nuestra: es el contrato de la herramienta.
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ---------------------------------------------------------------------------
# Presupuesto: la red de seguridad
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "mensual" {
  name         = "${var.project_name}-presupuesto-mensual"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 50% del gasto real: informativo, "vas a la mitad".
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # 80% del gasto real: revisa que dejaste encendido.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # 100% PROYECTADO: esta es la alerta que de verdad sirve. AWS extrapola el
  # ritmo de gasto y avisa el dia 3 de que a este paso vas a pasarte a fin de
  # mes. Las otras dos avisan cuando el dinero ya se gasto.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# ---------------------------------------------------------------------------
# Puente hacia el stack principal
# ---------------------------------------------------------------------------
# Los bloques `backend` de Terraform no admiten variables ni interpolacion:
# se leen antes de que exista un contexto donde evaluarlas. Y el nombre del
# bucket depende del ID de la cuenta, que cambia segun quien lo aplique.
#
# La salida a ese callejon es la "configuracion parcial": el backend declara
# solo su tipo, y los valores concretos llegan en un archivo aparte con
# `terraform init -backend-config=backend.hcl`.
#
# Este recurso genera ese archivo automaticamente. Quien clone el repo corre
# el bootstrap y obtiene su propio backend.hcl, con el nombre de bucket de SU
# cuenta, sin editar nada a mano.
resource "local_file" "backend_config" {
  filename        = "${path.module}/../infra/backend.hcl"
  file_permission = "0644"

  content = <<-EOT
    # ARCHIVO GENERADO por bootstrap/main.tf - no lo edites a mano.
    # Uso: cd infra && terraform init -backend-config=backend.hcl
    bucket         = "${aws_s3_bucket.tfstate.id}"
    key            = "infra/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.tflock.name}"
    use_lockfile   = true
    encrypt        = true
    ${local.backend_profile_line}
  EOT
}

# El propio bootstrap tambien guarda su estado en el bucket que crea. Fijate en
# la clave: `bootstrap/terraform.tfstate`, distinta de la del stack principal.
# Dos stacks, dos estados separados dentro del mismo bucket. Cada uno se puede
# aplicar y destruir sin tocar al otro.
resource "local_file" "backend_config_bootstrap" {
  filename        = "${path.module}/backend.hcl"
  file_permission = "0644"

  content = <<-EOT
    # ARCHIVO GENERADO por bootstrap/main.tf - no lo edites a mano.
    # Uso: cd bootstrap && terraform init -backend-config=backend.hcl
    bucket         = "${aws_s3_bucket.tfstate.id}"
    key            = "bootstrap/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.tflock.name}"
    use_lockfile   = true
    encrypt        = true
    ${local.backend_profile_line}
  EOT
}
