# Plataforma reproducible en AWS con Terraform y GitOps

Infraestructura de una aplicación web en AWS definida **enteramente en código**.
Nada se crea a mano en la consola: si no está en un archivo `.tf`, no existe.
Los cambios de infraestructura se revisan en Pull Requests igual que el código
de una aplicación, y se aplican solos cuando alguien los aprueba.

> **Estado:** en construcción. Fases 1 y 2 de 6 completadas.
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

### Verificación de la red

Una subnet no es «pública» o «privada» por ninguna propiedad suya: lo que la
define es a dónde apunta su tabla de rutas. Comprobado contra la API de AWS
sobre el ambiente real:

```
SUBNET                     AZ           CIDR             TIER     RUTA 0.0.0.0/0 ->
subnet-01312b7174c413fb7   us-east-1b   10.42.241.0/24   public   igw-063f9dd5a2951817d
subnet-0a1563b7e75881f30   us-east-1a   10.42.240.0/24   public   igw-063f9dd5a2951817d
subnet-06a1f9685f7c516e8   us-east-1b   10.42.16.0/20    private  nat-0171bbc8d0570958f
subnet-0f7019b663f415c1a   us-east-1a   10.42.0.0/20     private  nat-0171bbc8d0570958f

NAT nat-0171bbc8d0570958f  estado=available  vive en subnet public (us-east-1a)
VPC Endpoint vpce-0aa227a…  com.amazonaws.us-east-1.s3  Gateway  tablas asociadas=2
```

Lo que **no** aparece importa tanto como lo que sí: ninguna tabla privada tiene
ruta hacia el Internet Gateway. La base de datos no es inalcanzable desde fuera
por un firewall, sino porque no existe un camino hasta ella.

Las subnets privadas son `/20` (4.091 direcciones usables) porque cada tarea de
Fargate consume una IP propia; las públicas son `/24` (251) porque solo alojan
el balanceador y el NAT. AWS reserva 5 direcciones en cada subnet, de ahí que no
sean 4.096 y 256.

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

### Un solo NAT Gateway, no uno por zona

| Opción | Costo/mes | Qué ganas / qué pierdes |
|---|---|---|
| Un NAT por AZ | ~64 USD | Alta disponibilidad real de la salida a internet |
| **Un solo NAT** | **~32 USD** | Si esa AZ cae, las privadas pierden salida |
| NAT instance (`t4g.nano`) | ~3 USD | Mucho más barato; hay que parchar el SO y gestionarlo |
| Solo VPC endpoints, sin NAT | ~58 USD | Suena elegante, sale **más caro**: 4 endpoints × 2 AZ |

Perder el NAT no tumba la aplicación: el balanceador sigue recibiendo tráfico y
las tareas siguen respondiendo. Lo único que se rompe es que las tareas no
pueden *iniciar* conexiones salientes. Pagar el doble por eso en un ambiente que
vive horas no se justifica.

Es una variable, no una constante: `single_nat_gateway = false` crea uno por AZ
y cada tabla de rutas privada pasa a usar el de su zona, sin tocar nada más. En
producción, con tráfico real, esa es la respuesta correcta.

### Endpoint de S3 tipo Gateway

Todo byte que sale por el NAT Gateway se cobra a 0,045 USD/GB. Las imágenes de
contenedor de ECR se almacenan por debajo en S3, así que sin este endpoint cada
despliegue pagaría peaje por descargar su propia imagen.

Los endpoints de tipo **Gateway** son gratuitos (los de tipo *Interface* cuestan
~0,01 USD/hora por AZ). El tráfico hacia S3 deja de atravesar el NAT y deja de
generar cargo.

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

### El backend se autentica aparte del provider

Terraform habla con AWS por **dos caminos independientes**, y es una fuente
clásica de confusión:

| Camino | Para qué | De dónde saca las credenciales |
|---|---|---|
| `provider "aws"` | Crear y modificar recursos | `var.aws_profile`, desde `terraform.tfvars` |
| `backend "s3"` | Leer y escribir el estado | **Solo** de `backend.hcl` o del entorno |

El backend se inicializa *antes* de que las variables existan, así que no puede
leer `terraform.tfvars`. Si `backend.hcl` no lleva `profile` y el entorno no
tiene `AWS_PROFILE`, Terraform acaba preguntándole a `169.254.169.254` —la
dirección desde la que una instancia EC2 pide su rol— y falla con un
desconcertante `unreachable network`.

Por eso el bootstrap escribe `profile` dentro del `backend.hcl` que genera. En
CI ese valor es `null` y la línea sencillamente no se emite, porque allí las
credenciales llegan por rol IAM.

Si prefieres no depender de eso, la alternativa es exportar la variable de
entorno, que cubre ambos caminos a la vez:

```powershell
Set-Item Env:AWS_PROFILE infra-aws     # PowerShell
```
```bash
export AWS_PROFILE=infra-aws           # bash
```

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
- [x] **Fase 2 — Red.** VPC, subnets públicas y privadas en 2 AZ, Internet
      Gateway, NAT Gateway, tablas de rutas, endpoint de S3.
- [ ] **Fase 3 — Base de datos.** RDS PostgreSQL, Security Groups, credenciales
      en Secrets Manager.
- [ ] **Fase 4 — Cómputo y balanceo.** ECR, ECS Fargate, ALB, health checks,
      auto scaling.
- [ ] **Fase 5 — GitOps.** `plan` comentado en cada PR, `apply` tras aprobación
      manual en merge.
- [ ] **Fase 6 — Documentación y evidencia.** Capturas del flujo completo de un
      PR de infraestructura.
