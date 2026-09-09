# ===========================================================================
# ACCESO DE GITHUB ACTIONS A AWS, SIN SECRETOS
# ===========================================================================
# La forma habitual de dar acceso a un pipeline es crear una llave de IAM y
# pegarla en los secretos del repositorio. Tiene tres problemas: no caduca
# nunca, vive en un sistema que no controlas, y quien la extraiga puede usarla
# desde cualquier lugar del mundo.
#
# OIDC invierte la relacion. GitHub firma un token que afirma "soy el
# repositorio X, corriendo en la rama Y". AWS verifica esa firma contra las
# claves publicas de GitHub y, si el token encaja con lo que esta cuenta ha
# declarado que confia, entrega credenciales TEMPORALES que caducan en una hora.
#
# No hay ningun secreto que robar, porque no hay ningun secreto.
# ===========================================================================

# Declara ante AWS que las identidades firmadas por GitHub son verificables.
# Por si solo no concede nada: solo establece a quien se le reconoce la firma.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "github-actions"
  }
}

# ---------------------------------------------------------------------------
# En que condiciones exactas se confia
# ---------------------------------------------------------------------------
# Esta es la parte que de verdad importa. Un error habitual es poner
# `repo:*:*`, que permitiria a CUALQUIER repositorio de GitHub —el de un
# desconocido incluido— asumir este rol y operar en tu cuenta de AWS.
#
# Aqui se enumeran tres situaciones concretas y ninguna mas:
data "aws_iam_policy_document" "github_confianza" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # El token debe estar destinado al servicio de tokens de AWS y no a otro
    # receptor. Sin esta condicion, un token emitido para otro destinatario
    # podria reutilizarse aqui.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        # Un push a la rama principal: es donde corre el apply.
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",

        # Un Pull Request: es donde corre el plan. Solo lectura en la practica,
        # pero necesita escribir el cerrojo del estado.
        "repo:${var.github_owner}/${var.github_repo}:pull_request",

        # Un job que corre dentro del entorno protegido, es decir, despues de
        # que una persona haya aprobado el despliegue a mano.
        "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project_name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_confianza.json

  # Una hora. El pipeline mas largo de este proyecto tarda minutos; no hay
  # razon para que las credenciales vivan mas que el trabajo que las necesita.
  max_session_duration = 3600

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

# El pipeline usa exactamente los mismos permisos que tu usuario local, leidos
# del MISMO archivo. Si manana se anade un servicio, se edita un solo sitio y
# ambos quedan al dia: no hay forma de que el pipeline y tu maquina se
# desincronicen sin que nadie lo note.
resource "aws_iam_policy" "github_actions" {
  name        = "${var.project_name}-github-actions"
  description = "Mismos permisos acotados que el usuario local de Terraform"
  policy      = file("${path.module}/../docs/iam-policy-terraform.json")

  tags = {
    Name = "${var.project_name}-github-actions"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}
