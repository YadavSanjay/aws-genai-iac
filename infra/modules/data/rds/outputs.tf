output "instance_id" {
  description = "DB instance identifier."
  value       = aws_db_instance.this.id
}

output "instance_arn" {
  description = "DB instance ARN."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "DNS address of the instance (no port). Set as XBRL_DB_HOST on consumers."
  value       = aws_db_instance.this.address
}

output "endpoint" {
  description = "address:port endpoint."
  value       = aws_db_instance.this.endpoint
}

output "port" {
  description = "Listener port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user login."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = <<-EOT
    ARN of the AWS-managed master-user secret (Secrets Manager). The credential is
    here, never in Terraform state — consumers grant secretsmanager:GetSecretValue
    on this ARN and read {username,password,host,port,dbname} at runtime.
  EOT
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "subnet_group_name" {
  description = "DB subnet group name."
  value       = aws_db_subnet_group.this.name
}

output "parameter_group_name" {
  description = "DB parameter group name."
  value       = aws_db_parameter_group.this.name
}

output "log_group_name" {
  description = "CloudWatch log group receiving the exported postgresql log."
  value       = aws_cloudwatch_log_group.postgres.name
}

output "scheduler_role_arn" {
  description = "Role EventBridge Scheduler assumes to stop/start the instance; null when unscheduled."
  value       = one(aws_iam_role.scheduler[*].arn)
}

output "start_schedule_name" {
  description = "Name of the start schedule; null when unscheduled OR parked (stop-only)."
  value       = one(aws_scheduler_schedule.start[*].name)
}

output "stop_schedule_name" {
  description = "Name of the stop schedule; null when unscheduled."
  value       = one(aws_scheduler_schedule.stop[*].name)
}

output "schedule_summary" {
  description = "Human-readable window, including the timezone the crons are evaluated in."
  value = (
    !local.schedule_requested
    ? "unscheduled (runs 24x7)"
    : local.start_count == 0
    ? "PARKED: stop cron(${var.stop_cron}) in ${var.schedule_timezone}, no start (${var.schedule_enabled ? "ENABLED" : "DISABLED"})"
    : "start cron(${var.start_cron}) / stop cron(${var.stop_cron}) in ${var.schedule_timezone} (${var.schedule_enabled ? "ENABLED" : "DISABLED"})"
  )
}
