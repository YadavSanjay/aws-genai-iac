output "instance_id" {
  description = "Instance id. Use for start/stop scheduling and Session Manager."
  value       = aws_instance.qdrant.id
}

output "private_ip" {
  description = "Private address. There is no public one by design."
  value       = aws_instance.qdrant.private_ip
}

output "availability_zone" {
  description = "AZ the host (and its data volume) landed in. Keep consumers here too so vector traffic stays same-AZ ($0)."
  value       = aws_instance.qdrant.availability_zone
}

output "discovery_fqdn" {
  description = "Stable in-VPC name consumers connect to (Cloud Map A record)."
  value       = local.discovery_fqdn
}

output "endpoint" {
  description = "Full REST endpoint consumers use (TLS, self-signed in dev — clients trust the cert or skip-verify in-VPC)."
  value       = "https://${local.discovery_fqdn}:${var.rest_port}"
}

output "rest_port" {
  description = "Qdrant REST port."
  value       = var.rest_port
}

output "grpc_port" {
  description = "Qdrant gRPC port."
  value       = var.grpc_port
}

output "data_volume_id" {
  description = "EBS data volume id. Target for AWS Backup / manual snapshots; survives instance replacement."
  value       = aws_ebs_volume.data.id
}

output "role_arn" {
  description = "Instance role ARN."
  value       = aws_iam_role.qdrant.arn
}

output "role_name" {
  description = "Instance role name. Use to grant additional scoped access as the store grows."
  value       = aws_iam_role.qdrant.name
}

output "session_manager_command" {
  description = "Ready-to-run Session Manager command. There is no SSH path."
  value       = "aws ssm start-session --target ${aws_instance.qdrant.id} --region <region> --profile <profile>"
}
