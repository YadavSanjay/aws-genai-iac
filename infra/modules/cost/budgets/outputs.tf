output "sns_topic_arn" {
  description = "ARN of the cost-alert SNS topic. Reuse for other cost/billing alarms."
  value       = aws_sns_topic.cost_alerts.arn
}

output "sns_topic_name" {
  description = "Name of the cost-alert SNS topic."
  value       = aws_sns_topic.cost_alerts.name
}

output "budget_name" {
  description = "Name of the account-wide monthly cost budget."
  value       = aws_budgets_budget.monthly.name
}

output "anomaly_monitor_arn" {
  description = "ARN of the Cost Anomaly Detection service monitor."
  value       = aws_ce_anomaly_monitor.services.arn
}

output "pending_email_subscriptions" {
  description = <<-EOT
    Email addresses subscribed to the topic. Each requires an out-of-band
    confirmation click before it delivers anything — verify with the post-apply
    check, not by trusting a successful apply.
  EOT
  value       = [for s in aws_sns_topic_subscription.email : s.endpoint]
}
