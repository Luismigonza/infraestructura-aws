output "state_bucket" {
  description = "Bucket S3 que guarda el estado de Terraform."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  description = "Tabla DynamoDB que sirve de cerrojo del estado."
  value       = aws_dynamodb_table.tflock.name
}

output "account_id" {
  description = "Cuenta de AWS donde se aplico este stack."
  value       = data.aws_caller_identity.current.account_id
}

output "siguiente_paso" {
  description = "Que hacer despues de aplicar el bootstrap."
  value       = "Se genero infra/backend.hcl. Ahora: cd ../infra && terraform init -backend-config=backend.hcl"
}
