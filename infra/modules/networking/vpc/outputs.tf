output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC. Use for resource policies and IAM conditions."
  value       = aws_vpc.this.arn
}

output "cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway, or null when not created. Needed by the public route table."
  value       = try(aws_internet_gateway.this[0].id, null)
}

output "default_security_group_id" {
  description = <<-EOT
    ID of the VPC's default security group, which this module strips to
    deny-all. Exported so a check can assert nothing is attached to it — it is
    not intended for use.
  EOT
  value       = aws_default_security_group.this.id
}

output "flow_log_id" {
  description = "ID of the flow log, or null when flow logging is disabled."
  value       = try(aws_flow_log.this[0].id, null)
}
