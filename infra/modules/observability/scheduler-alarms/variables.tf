variable "name_prefix" {
  description = "Prefix applied to alarm names (e.g. genai-dev)."
  type        = string
}

variable "alert_topic_arn" {
  description = <<-EOT
    SNS topic the alarms publish to (observability/alerts). Its policy must permit
    cloudwatch.amazonaws.com to publish, and at least one subscription must be
    CONFIRMED — an alarm wired to a topic nobody has confirmed is the same silent
    failure it exists to catch, one level up.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:sns:", var.alert_topic_arn))
    error_message = "alert_topic_arn must be an SNS topic ARN."
  }
}

variable "schedule_group" {
  description = <<-EOT
    EventBridge Scheduler group to watch. "default" covers every schedule in this
    estate — they are all created in the default group.

    Scheduler emits these metrics per GROUP, not per schedule, so an alarm cannot
    say which schedule failed. Attribute it by which schedules share that minute
    (the crons are in the components), or narrow the blast radius later by giving
    each workload its own group.
  EOT
  type        = string
  default     = "default"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
