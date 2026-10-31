variable "secrets" {
  description = <<-EOT
    Secret containers to create, keyed by name.

    Only the CONTAINER is created — never the value. See the note in main.tf.

    Prefer ONE secret per application holding a JSON object of its credentials,
    rather than one secret per credential. Secrets Manager bills $0.40 per
    secret per month regardless of size, so five separate API keys cost $2.00
    where one JSON blob costs $0.40 — and an application almost always needs all
    of its own credentials anyway, so the finer granularity buys nothing.

    Split only when different principals genuinely need different subsets.

    `reader_role_arn_patterns` is PER SECRET: the resource-policy reader set for
    that one secret. It must be per-secret, not a single list across the whole
    component — a component holding several applications' secrets would otherwise
    attach one application's reader set to another's secret, locking the real
    owner out of its own credential. Empty (default) means IAM-only access for
    that secret.
  EOT
  type = map(object({
    description              = string
    reader_role_arn_patterns = optional(list(string), [])
  }))

  validation {
    condition     = length(var.secrets) > 0
    error_message = "At least one secret is required."
  }

  # Deliberate ceiling, agreed 2026-07-20. At $0.40/secret/month this is the
  # difference between $2/month and an unbounded line item that grows one
  # forgotten secret at a time. Raising it should be a decision, not a drift.
  validation {
    condition     = length(var.secrets) <= 5
    error_message = "At most 5 secrets. Each costs $0.40/month; prefer one JSON secret per application over one per credential. Raise this ceiling deliberately if genuinely needed."
  }

  validation {
    condition = alltrue([
      for name in keys(var.secrets) : can(regex("^[a-zA-Z0-9/_+=.@-]{1,512}$", name))
    ])
    error_message = "Secret names may contain alphanumerics and / _ + = . @ - only."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    CMK encrypting the secret values.

    Required. Secrets Manager would otherwise fall back to the AWS-managed
    aws/secretsmanager key, which cannot be given a scoped key policy and does
    not rotate on our schedule.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "recovery_window_days" {
  description = <<-EOT
    Days a deleted secret remains recoverable before permanent destruction.

    0 forces immediate deletion, which is unrecoverable — allowed only because
    tearing dev down repeatedly is otherwise blocked by name collisions with
    still-pending deletions. Never use 0 in prod.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.recovery_window_days == 0 || (var.recovery_window_days >= 7 && var.recovery_window_days <= 30)
    error_message = "recovery_window_days must be 0 (immediate, unrecoverable) or between 7 and 30."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
