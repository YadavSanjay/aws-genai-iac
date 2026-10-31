output "key_id" {
  description = "KMS key id (UUID)."
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "KMS key ARN. Use for resource policies and IAM conditions."
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = <<-EOT
    Alias including the "alias/" prefix. Prefer this over key_id in downstream
    modules so a key replacement does not require editing every consumer.
  EOT
  value       = aws_kms_alias.this.name
}

output "alias_arn" {
  description = "ARN of the alias."
  value       = aws_kms_alias.this.arn
}
