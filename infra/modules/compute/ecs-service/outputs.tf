output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "ECS cluster name. Used in the autoscaling resource id and ECS Exec commands."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ECS service ARN."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "Active task definition ARN."
  value       = aws_ecs_task_definition.this.arn
}

output "service_discovery_service_arn" {
  description = "Cloud Map service ARN, or null when service discovery is not enabled."
  value       = try(aws_service_discovery_service.this[0].arn, null)
}

output "service_fqdn" {
  description = <<-EOT
    In-VPC DNS name the service resolves at (<app_name>.<namespace>), or null
    when service discovery is not enabled. Clients set their RAGINFER_URL-style
    endpoint to http://<this>:<container_port>.
  EOT
  value       = var.service_discovery_namespace_id != "" && var.service_discovery_namespace_name != "" ? "${var.app_name}.${var.service_discovery_namespace_name}" : null
}

output "execution_role_arn" {
  description = "Execution role ARN (ECR pull, log write, secret read)."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "Task role ARN (the container's identity: scoped S3 read, ECS Exec)."
  value       = aws_iam_role.task.arn
}

output "task_role_name" {
  description = "Task role name. Use to grant additional scoped access as the app grows."
  value       = aws_iam_role.task.name
}

output "log_group_name" {
  description = "CloudWatch log group the container streams to."
  value       = aws_cloudwatch_log_group.this.name
}

output "autoscaling_resource_id" {
  description = <<-EOT
    Application Auto Scaling resource id for the service's DesiredCount
    (service/<cluster>/<service>) — the handle used to add scheduled actions.
  EOT
  value       = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
}

output "execute_command" {
  description = "Ready-to-run ECS Exec command template (there is no SSH into Fargate)."
  value       = "aws ecs execute-command --cluster ${aws_ecs_cluster.this.name} --task <task-id> --container ${var.app_name} --interactive --command /bin/sh --region <region> --profile <profile>"
}
