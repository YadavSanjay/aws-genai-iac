output "secret_arns" {
  description = <<-EOT
    Map of secret name -> ARN.

    Use these to scope secretsmanager:GetSecretValue on application roles. The
    exec role's own grant is already scoped to genai-* by ARN.
  EOT
  value       = { for name, secret in aws_secretsmanager_secret.this : name => secret.arn }
}

output "secret_names" {
  description = "Names of the created secret containers."
  value       = keys(aws_secretsmanager_secret.this)
}

output "set_value_commands" {
  description = <<-EOT
    Ready-to-run commands for setting each value out of band.

    Values are deliberately not managed by Terraform — see the note in main.tf.
    Run these as an identity holding secretsmanager:PutSecretValue.
  EOT
  value = [
    for name, secret in aws_secretsmanager_secret.this :
    "aws secretsmanager put-secret-value --secret-id ${name} --secret-string '<json>' --region <region>"
  ]
}
