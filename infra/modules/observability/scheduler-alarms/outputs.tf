output "target_error_alarm_name" {
  description = "Alarm on invocations refused by their target."
  value       = aws_cloudwatch_metric_alarm.target_errors.alarm_name
}

output "invocations_dropped_alarm_name" {
  description = "Alarm on invocations abandoned after exhausting retries."
  value       = aws_cloudwatch_metric_alarm.invocations_dropped.alarm_name
}

output "alarm_names" {
  description = "Both alarm names, for post-apply verification."
  value = [
    aws_cloudwatch_metric_alarm.target_errors.alarm_name,
    aws_cloudwatch_metric_alarm.invocations_dropped.alarm_name,
  ]
}
