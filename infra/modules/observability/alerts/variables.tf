variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    Addresses subscribed to the topic. Each requires an out-of-band confirmation
    click before it delivers anything.

    Validated non-empty: a topic nobody is told about is not detection. These are
    personal addresses and belong in the gitignored account.local.hcl, never in a
    committed file.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert email is required — an alarm with no subscriber is not detection."
  }

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@ ]+@[^@ ]+\\.[^@ ]+$", e))])
    error_message = "alert_emails must be email addresses."
  }
}

variable "kms_master_key_id" {
  description = <<-EOT
    Key encrypting the topic at rest. Defaults to the AWS-managed SNS key.

    Think twice before pointing this at a project CMK: every publishing principal
    (CloudWatch alarms publish as a service principal) then needs
    kms:GenerateDataKey*/Decrypt on that key, and a missing grant means the alarm
    fires and the notification is silently dropped.
  EOT
  type        = string
  default     = "alias/aws/sns"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
