output "topic_arn" {
  description = "ARN of the operational alert topic. Alarms set this as alarm_actions."
  value       = aws_sns_topic.ops.arn
}

output "topic_name" {
  description = "Name of the operational alert topic."
  value       = aws_sns_topic.ops.name
}

output "subscribed_emails" {
  description = "Addresses subscribed. Each still needs its confirmation click before it delivers."
  value       = var.alert_emails
}
