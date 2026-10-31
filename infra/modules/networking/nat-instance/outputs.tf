output "instance_id" {
  description = "NAT instance id. Use for start/stop scheduling."
  value       = aws_instance.nat.id
}

output "network_interface_id" {
  description = <<-EOT
    Primary ENI, which is what the private route tables target.

    It survives a stop/start, so the route stays valid across the scheduled
    shutdown — no route churn, no automation needed to restore egress.
  EOT
  value       = aws_instance.nat.primary_network_interface_id
}

output "private_ip" {
  description = "Private address of the NAT instance."
  value       = aws_instance.nat.private_ip
}

output "security_group_id" {
  description = "NAT security group id."
  value       = aws_security_group.nat.id
}

output "role_arn" {
  description = "Instance role ARN. Session Manager access only."
  value       = aws_iam_role.nat.arn
}

output "ami_id" {
  description = <<-EOT
    AMI in use. Pinned by `ignore_changes` after creation, so a newer AL2023
    release will NOT silently replace the instance — refresh is deliberate.
  EOT
  value       = aws_instance.nat.ami
}
