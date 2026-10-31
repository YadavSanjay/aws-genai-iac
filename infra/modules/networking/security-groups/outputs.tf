output "alb_security_group_id" {
  description = "Public ALB security group. Attach to the load balancer."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = <<-EOT
    Application tier security group. Attach to app instances and ECS tasks.

    Later tiers (Qdrant, RDS) should grant ingress by REFERENCING this group id
    rather than a CIDR, so the rule stays correct as instances come and go.
  EOT
  value       = aws_security_group.app.id
}

output "app_port" {
  description = "Port the ALB forwards to, echoed so target groups stay consistent with the SG rules."
  value       = var.app_port
}

output "raginfer_security_group_id" {
  description = <<-EOT
    RagInference service security group. Attach to the Fargate tasks.

    Ingress is the ALB only; egress is AWS services + S3. Reached THROUGH the
    internal ALB, so clients egress to the ALB group rather than to this one.
  EOT
  value       = aws_security_group.raginfer.id
}

output "raginfer_port" {
  description = "Port the ALB forwards to RagInference on, echoed so its target group stays consistent."
  value       = var.raginfer_port
}

output "qdrant_security_group_id" {
  description = <<-EOT
    Qdrant data tier security group. Attach to the data/qdrant EC2 host.

    Ingress is the app tier (and later the ARag ingest group) on 6333/6334;
    egress is AWS services only.
  EOT
  value       = aws_security_group.qdrant.id
}

output "qdrant_rest_port" {
  description = "Qdrant REST port, echoed so the data/qdrant host and its consumers stay consistent with the SG rules."
  value       = var.qdrant_rest_port
}

output "qdrant_grpc_port" {
  description = "Qdrant gRPC port, echoed so the data/qdrant host and its consumers stay consistent with the SG rules."
  value       = var.qdrant_grpc_port
}

output "rds_security_group_id" {
  description = <<-EOT
    ARag RDS data tier security group. Attach to the data/rds instance.

    Ingress is the app tier (and later the ARag ingest group) on 5432; it
    initiates no egress.
  EOT
  value       = aws_security_group.rds.id
}

output "rds_port" {
  description = "RDS PostgreSQL port, echoed so the data/rds instance and its consumers stay consistent with the SG rules."
  value       = var.rds_port
}
