output "role_arn" {
  description = "Role EventBridge Scheduler assumes to start/stop the instances."
  value       = aws_iam_role.scheduler.arn
}

output "stop_schedule_name" {
  description = "Name of the stop schedule."
  value       = aws_scheduler_schedule.stop.name
}

output "start_schedule_name" {
  description = "Name of the start schedule."
  value       = aws_scheduler_schedule.start.name
}

output "schedule_summary" {
  description = "Human-readable summary of the window, including the timezone the crons are evaluated in."
  value       = "start cron(${var.start_cron}) / stop cron(${var.stop_cron}) in ${var.timezone} (${var.enabled ? "ENABLED" : "DISABLED"})"
}
