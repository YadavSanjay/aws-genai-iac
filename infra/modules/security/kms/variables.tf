variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "account_id" {
  description = "AWS account id owning the key. Used for the anti-lockout delegation and caller conditions."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "region" {
  description = "Region the key lives in. Used to build kms:ViaService principals."
  type        = string
}

variable "alias" {
  description = <<-EOT
    Alias suffix, without the "alias/" prefix. Final alias is
    "alias/<name_prefix>-<alias>", e.g. alias/genai-dev-primary.
  EOT
  type        = string
  default     = "primary"
}

variable "description" {
  description = "Human-readable key description shown in the console."
  type        = string
  default     = "Shared customer-managed key for project data at rest."
}

variable "deletion_window_days" {
  description = <<-EOT
    Days AWS waits before destroying the key after ScheduleKeyDeletion.

    This is the only recovery window: once elapsed, every object encrypted with
    the key is permanently unreadable. Short in dev (fast teardown), long in
    prod (time to notice a mistake).
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.deletion_window_days >= 7 && var.deletion_window_days <= 30
    error_message = "deletion_window_days must be between 7 and 30 (AWS limit)."
  }
}

variable "enable_rotation" {
  description = "Automatic annual rotation of the key material. Should stay true."
  type        = bool
  default     = true
}

variable "rotation_period_days" {
  description = "Days between automatic rotations. AWS allows 90-2560."
  type        = number
  default     = 365

  validation {
    condition     = var.rotation_period_days >= 90 && var.rotation_period_days <= 2560
    error_message = "rotation_period_days must be between 90 and 2560."
  }
}

variable "via_services" {
  description = <<-EOT
    AWS service short names permitted to use the key on a principal's behalf,
    enforced with the kms:ViaService condition. A principal listed nowhere else
    therefore cannot call Decrypt directly — only these services can, and only
    for a caller in this account.

    Keep this to services actually in use; every entry widens the data plane.
  EOT
  type        = list(string)
  default = [
    "s3",
    "secretsmanager",
    "ssm",
    "sns",
    "sqs",
    "logs",
    "ecr",
    "rds",
    "dynamodb",
    "backup",
    "ebs",
    "elasticfilesystem",
    # EventBridge Scheduler encrypts each schedule's target input at rest.
    "scheduler",
  ]

  validation {
    condition     = length(var.via_services) > 0
    error_message = "via_services cannot be empty — the key would be unusable by any service."
  }
}

variable "allow_aws_log_delivery" {
  description = <<-EOT
    Grant the AWS log-delivery service principal use of the key.

    Required when an SSE-KMS bucket receives VPC flow logs, ALB access logs, or
    similar. Without it, delivery fails SILENTLY — AWS reports the flow log as
    "active" and simply never writes objects, which reads like a networking
    problem rather than a permissions one.

    Confused-deputy gated on aws:SourceAccount.
  EOT
  type        = bool
  default     = false
}

variable "allow_cloudwatch_logs" {
  description = <<-EOT
    Grant the CloudWatch Logs service principal direct use of the key, scoped by
    encryption context to log groups in this account/region.

    Log-group encryption needs this in addition to the kms:ViaService grant,
    because Logs calls KMS with its own service principal rather than on behalf
    of the requester.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
