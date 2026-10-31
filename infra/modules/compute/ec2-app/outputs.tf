output "instance_id" {
  description = "Instance id. Use for start/stop scheduling and Session Manager."
  value       = aws_instance.app.id
}

output "private_ip" {
  description = "Private address. There is no public one by design."
  value       = aws_instance.app.private_ip
}

output "data_volume_id" {
  description = "Dedicated data volume id, or null when data_volume_gb is 0."
  value       = try(aws_ebs_volume.data[0].id, null)
}

output "role_arn" {
  description = "Instance role ARN."
  value       = aws_iam_role.app.arn
}

output "role_name" {
  description = "Instance role name. Use to grant additional scoped access as the app grows."
  value       = aws_iam_role.app.name
}

output "availability_zone" {
  description = "AZ the instance landed in. Relevant for keeping NAT traffic same-AZ."
  value       = aws_instance.app.availability_zone
}

output "session_manager_command" {
  description = "Ready-to-run Session Manager command. There is no SSH path."
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region <region> --profile <profile>"
}

output "discovery_fqdn" {
  description = <<-EOT
    Stable in-VPC name callers connect to, or "" when discovery is not enabled.
    Consumers should wire THIS into a base-URL setting rather than private_ip:
    the record is rewritten in the same apply that replaces the instance, whereas
    a copied address goes stale silently.
  EOT
  value       = local.register_discovery ? "${local.discovery_name}.${var.service_discovery_namespace_name}" : ""
}
