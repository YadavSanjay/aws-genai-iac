output "exec_role_arn" {
  description = "ARN of the Terraform execution role. Wire into the provider assume_role block / --terragrunt-iam-role."
  value       = aws_iam_role.exec.arn
}

output "exec_role_name" {
  description = "Name of the Terraform execution role."
  value       = aws_iam_role.exec.name
}

output "app_boundary_arn" {
  description = "Permissions boundary ARN that every Terraform-created app role must carry. Pass to security/iam app-role modules as permissions_boundary."
  value       = aws_iam_policy.app_boundary.arn
}

output "managed_policy_arns" {
  description = "The customer-managed policy ARNs attached to the exec role."
  value       = local.managed_policies
}

output "terraform_user_name" {
  description = "Name of the Terraform IAM user, or null when create_terraform_user = false."
  value       = var.create_terraform_user ? aws_iam_user.tf[0].name : null
}

output "terraform_user_arn" {
  description = "ARN of the Terraform IAM user, or null when create_terraform_user = false. Mint keys with `aws iam create-access-key --user-name <name>`."
  value       = var.create_terraform_user ? aws_iam_user.tf[0].arn : null
}
