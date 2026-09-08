# Plataforma reproducible en AWS con Terraform y GitOps

Infraestructura de una aplicación web en AWS definida **enteramente en código**.
Nada se crea a mano en la consola: si no está en un archivo `.tf`, no existe.
Los cambios de infraestructura se revisan en Pull Requests igual que el código
de una aplicación, y se aplican solos cuando alguien los aprueba.

> **Estado:** en construcción. Fase 1 de 6 completada.
> Ver [Hoja de ruta](#hoja-de-ruta).

---

## Arquitectura

```
                    Internet
                        │
                        ▼
        ┌───────────────────────────────┐
        │  Application Load Balancer    │   subnets públicas, 2 AZ
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │  ECS Fargate (contenedor)     │   subnets privadas, 2 AZ
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │  RDS PostgreSQL               │   subnets privadas, sin salida
        └───────────────────────────────┘
```

Todo dentro de una VPC propia. Las subnets privadas salen a internet a través de
un NAT Gateway; nadie desde internet puede alcanzarlas.

---

## Estructura del repositorio

| Ruta | Qué contiene |
|---|---|
| `bootstrap/` | Lo que debe existir antes que Terraform pueda gestionar nada: bucket de estado, cerrojo y presupuesto. Se aplica una vez. |
| `infra/` | El stack principal. Ensambla los módulos. |
| `infra/modules/network/` | VPC, subnets, Internet Gateway, NAT Gateway, tablas de rutas. |
| `infra/modules/database/` | RDS PostgreSQL, Security Groups, secreto de credenciales. |
| `infra/modules/compute/` | ECR, tarea y servicio de ECS Fargate, auto scaling. |
| `infra/modules/loadbalancer/` | Application Load Balancer, target group, health checks. |
| `app/` | Aplicación de ejemplo y su `Dockerfile`. |
| `.github/workflows/` | Pipelines de `plan` en PR y `apply` en merge. |
| `docs/` | Política IAM y material de apoyo. |

Los dos stacks (`bootstrap` e `infra`) tienen **estados separados** dentro del
mismo bucket. Cada uno se aplica y se destruye sin tocar al otro.

---

## Decisiones técnicas

Cada decisión no obvia está justificada. El *porqué* importa más que el *qué*.

### Usuario IAM con permisos acotados, no `AdministratorAccess`

La política está versionada en [`docs/iam-policy-terraform.json`](docs/iam-policy-terraform.json)
y concede acceso solo a los servicios que este proyecto usa. Está verificado que
**no** puede leer la organización ni crear otros usuarios IAM:

```
$ aws organizations describe-organization
AccessDeniedException: You don't have permissions to access this resource.

$ aws iam create-user --user-name prueba
AccessDenied: ... is not authorized to perform: iam:CreateUser
```

Crear ese usuario es el único paso manual del proyecto, y es inevitable:
Terraform necesita credenciales para funcionar, y esas credenciales son a su vez
un recurso de AWS. Alguien tiene que abrir la puerta la primera vez.

### CIDR `10.42.0.0/16`

- `10.0.0.0/16` es el valor por defecto de casi todos los tutoriales y módulos
  públicos. Elegirlo garantiza un choque el día que esta VPC se empareje con
  otra red o con una VPN.
- `172.31.0.0/16` ya está ocupado: es el rango de la VPC por defecto que AWS
  crea en toda cuenta nueva, incluida esta.
- `192.168.0.0/16` es el rango típico de routers domésticos. Quien se conecte
  por VPN desde su casa tendría el mismo rango en ambos extremos.

`10.42.0.0/16` está en el espacio privado de la RFC 1918, deja 65.536
direcciones y no colisiona con ninguno de los tres.

### Doble mecanismo de bloqueo del estado

Sin cerrojo, dos `apply` simultáneos (tu máquina y el pipeline) parten de fotos
distintas de la realidad y el último en escribir pisa al otro.

El enunciado pide DynamoDB. Desde Terraform 1.10 el backend S3 sabe bloquear por
sí solo (`use_lockfile`) y `dynamodb_table` quedó **obsoleto**. Se mantienen los
dos: DynamoDB porque es requisito, y el bloqueo nativo porque el otro va camino
de desaparecer. El día que lo eliminen, se borra una línea y el cerrojo sigue
funcionando.

Consecuencia visible: `terraform init` imprime un aviso de parámetro obsoleto.
Es esperado, no un error.

### `force_destroy = true` en el bucket de estado

En producción se pondría `false` más `prevent_destroy`: borrar el estado por
accidente es catastrófico. Aquí se deja en `true` a propósito, porque el ciclo
de vida esperado de este proyecto incluye desmontarlo por completo y el
`terraform destroy` tiene que funcionar limpio de verdad. La red de seguridad
que se pierde la compensa el versionado del bucket.

### El nombre del bucket se calcula, no se escribe

Los nombres de bucket S3 son únicos **globalmente**. El bootstrap lo construye
como `tfstate-<proyecto>-<id-de-cuenta>`, tomando el ID de cuenta de las
credenciales activas. Así el mismo código funciona en la cuenta de cualquiera
sin editar nada.

Eso choca con una limitación de Terraform: los bloques `backend` no admiten
variables ni interpolación. La salida es la *configuración parcial*: el backend
declara solo su tipo y los valores concretos llegan en un `backend.hcl` que el
bootstrap **genera automáticamente**. Ese archivo no se versiona, porque es
específico de cada cuenta.

### HTTP, no HTTPS *(decisión pendiente de revisar)*

Este proyecto no tiene dominio propio, y AWS Certificate Manager no emite
certificados para el nombre DNS autogenerado de un balanceador. El ALB queda
sirviendo **HTTP en el puerto 80**.

No es una omisión: es una limitación asumida y documentada. Con un dominio, el
cambio son unas veinte líneas (un `aws_acm_certificate`, su validación por DNS,
y un listener en el 443 que redirige el 80).

---

## Costos

| Recurso | Costo aproximado |
|---|---|
| **NAT Gateway** | **~32 USD/mes** — el componente caro, no está en capa gratuita |
| Application Load Balancer | ~16 USD/mes |
| RDS `db.t3.micro` | gratis el primer año, luego ~13 USD/mes |
| ECS Fargate (1 tarea mínima) | ~9 USD/mes |
| S3 + DynamoDB (estado) | céntimos |
| AWS Budgets | gratis |

Por eso el ambiente **se levanta para trabajar y se destruye al terminar**. Hay
una alerta de presupuesto configurada desde antes de crear el primer recurso,
con avisos al 50 %, al 80 % y una proyección al 100 %. La proyección es la que
sirve: avisa el día 3 de que a ese ritmo te pasarás a fin de mes, no cuando el
dinero ya se gastó.

---

## Cómo levantar el ambiente desde cero

### Requisitos

- [Terraform](https://developer.hashicorp.com/terraform) >= 1.6
- [AWS CLI](https://aws.amazon.com/cli/) v2
- Una cuenta de AWS

### 1. Crear el usuario de Terraform *(una sola vez, a mano)*

En la consola de AWS:

1. **IAM → Policies → Create policy → JSON**: pega el contenido de
   [`docs/iam-policy-terraform.json`](docs/iam-policy-terraform.json) y nómbrala
   `TerraformPlatformDeploy`.
2. **IAM → Users → Create user**: nombre `terraform-infra-aws`, **sin** acceso a
   la consola, y adjunta la política anterior.
3. En el usuario, **Security credentials → Create access key → CLI**.

Configura el perfil local:

```bash
aws configure --profile infra-aws
```

### 2. Aplicar el bootstrap

Crea el bucket de estado, el cerrojo y la alerta de presupuesto.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # pon tu correo de alertas
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

Mueve su propio estado al bucket que acaba de crear:

```bash
terraform init -migrate-state -backend-config backend.hcl
```

Responde `yes` cuando pregunte si quiere copiar el estado existente. Responder
`no` haría que Terraform se olvidara de los recursos recién creados, que
seguirían existiendo y cobrando.

### 3. Aplicar el stack principal

El bootstrap dejó generado `infra/backend.hcl` con los datos de **tu** cuenta.

```bash
cd ../infra
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config backend.hcl
terraform plan -out tfplan
terraform apply tfplan
```

La URL de la aplicación sale como output al terminar.

---

## Cómo destruir el ambiente por completo

**El orden importa.** El stack principal primero; el bootstrap después, porque
guarda el estado de todo.

```bash
cd infra
terraform destroy
```

Para el bootstrap hay un detalle: guarda su propio estado dentro del bucket que
va a borrar. Hay que traerlo de vuelta al disco antes de destruirlo.

```bash
cd ../bootstrap

# 1. Comenta la línea `backend "s3" {}` en versions.tf
# 2. Trae el estado de vuelta a local:
terraform init -migrate-state

# 3. Ahora sí:
terraform destroy
```

Comprueba que no quedó nada huérfano:

```bash
aws ec2 describe-vpcs --profile infra-aws --query 'Vpcs[?IsDefault==`false`]'
aws rds describe-db-instances --profile infra-aws --query 'DBInstances[].DBInstanceIdentifier'
aws elbv2 describe-load-balancers --profile infra-aws --query 'LoadBalancers[].LoadBalancerName'
```

Las tres deberían salir vacías.

---

## Hoja de ruta

- [x] **Fase 1 — Cimientos.** Backend remoto (S3 + DynamoDB), presupuesto,
      estructura de módulos, usuario IAM acotado.
- [ ] **Fase 2 — Red.** VPC, subnets públicas y privadas en 2 AZ, Internet
      Gateway, NAT Gateway, tablas de rutas.
- [ ] **Fase 3 — Base de datos.** RDS PostgreSQL, Security Groups, credenciales
      en Secrets Manager.
- [ ] **Fase 4 — Cómputo y balanceo.** ECR, ECS Fargate, ALB, health checks,
      auto scaling.
- [ ] **Fase 5 — GitOps.** `plan` comentado en cada PR, `apply` tras aprobación
      manual en merge.
- [ ] **Fase 6 — Documentación y evidencia.** Capturas del flujo completo de un
      PR de infraestructura.
