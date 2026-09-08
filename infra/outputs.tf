# Los outputs son el contrato del stack con quien lo usa. La URL de la
# aplicacion vivira aqui: el paso 4 de la Definition of Done dice que quien
# clone el repo debe poder entrar a la app "por la URL que Terraform le
# devuelve como output".

output "region" {
  description = "Region donde se desplego el ambiente."
  value       = var.aws_region
}
