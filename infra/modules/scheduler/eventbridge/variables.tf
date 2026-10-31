variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "workload" {
  description = <<-EOT
    Short name distinguishing this schedule's resources, so the module can be
    instantiated more than once per environment without name collisions (the NAT
    on 10-22 and Qdrant on 11-21 are different windows, hence different schedules).

    Resources are named <name_prefix>-<workload>-{scheduler,start,stop}. Defaults
    to "instance" so pre-existing callers keep their names unchanged.
  EOT
  type        = string
  default     = "instance"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,24}$", var.workload))
    error_message = "workload must be lowercase alphanumeric with hyphens."
  }
}

variable "instance_ids" {
  description = "EC2 instances to start and stop on this schedule."
  type        = list(string)

  validation {
    condition     = length(var.instance_ids) > 0
    error_message = "At least one instance id is required."
  }

  validation {
    condition     = alltrue([for i in var.instance_ids : can(regex("^i-[0-9a-f]{8,17}$", i))])
    error_message = "instance_ids must be EC2 instance ids (i-...)."
  }
}

variable "timezone" {
  description = <<-EOT
    IANA timezone the cron expressions are interpreted in.

    Load-bearing: get this wrong and the instance is stopped during working
    hours. An IANA name (not a fixed UTC offset) is required so daylight saving
    is handled — "America/New_York" keeps 22:00 local across the DST boundary,
    where "UTC-4" would drift by an hour twice a year.
  EOT
  type        = string
  default     = "UTC"

  validation {
    condition     = can(regex("^[A-Za-z]+/[A-Za-z_+-]+$|^UTC$", var.timezone))
    error_message = "timezone must be an IANA name such as America/New_York, or UTC."
  }
}

variable "start_cron" {
  description = <<-EOT
    Cron for starting instances, in EventBridge Scheduler's 6-field format
    (minute hour day-of-month month day-of-week year).

    Note day-of-week and day-of-month are mutually exclusive — one must be "?".
  EOT
  type        = string
  default     = "0 10 * * ? *"
}

variable "stop_cron" {
  description = "Cron for stopping instances. Same format as start_cron."
  type        = string
  default     = "0 22 * * ? *"
}

variable "enabled" {
  description = <<-EOT
    Whether the schedules are active.

    Set false to keep instances running continuously without destroying the
    schedules — useful while debugging something overnight.
  EOT
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = <<-EOT
    CMK encrypting each schedule's target input at rest.

    The current payload is only a list of instance ids, which is not sensitive —
    but this module is reused for application schedules whose inputs carry more,
    and encrypting by default is cheaper than remembering to turn it on later.
    Costs ~60 KMS requests a month.

    The module grants the scheduler role kms:Decrypt on this key so it can decrypt
    the target input at invocation time; the key policy must permit that principal
    (IAM delegation or an explicit grant). NOTE: Scheduler calls KMS directly, NOT
    via a service, so do NOT gate that grant on kms:ViaService — that context key
    is absent and the decrypt (and thus the whole start/stop) silently fails.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the scheduler role. Required by the exec role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
