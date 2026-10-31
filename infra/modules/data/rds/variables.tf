variable "name" {
  description = <<-EOT
    Instance identifier and base name, e.g. "genai-dev-arag". The DB subnet group,
    parameter group and log group derive their names from it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,50}$", var.name))
    error_message = "name must be lowercase, start with a letter, and use only [a-z0-9-]."
  }
}

variable "vpc_security_group_ids" {
  description = <<-EOT
    Security groups attached to the instance. Expect the dedicated rds group from
    networking/security-groups, whose ingress (5432 from the app + ingest tiers)
    is wired there, not here — this module never opens the port itself.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.vpc_security_group_ids) > 0
    error_message = "At least one security group is required, or the instance is unreachable."
  }
}

variable "subnet_ids" {
  description = <<-EOT
    Private subnet ids for the DB subnet group. Two or more AZs are required by
    RDS even for a single-AZ instance (a Multi-AZ promotion must have somewhere to
    go); the instance still runs in one AZ until multi_az is set.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS requires subnets in at least two AZs, even for a single-AZ instance."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    CMK for storage-at-rest, the managed master-user secret, and the exported log
    group. A CMK rather than the AWS-managed key so the data, its credential and
    its logs all sit under the project key policy and rotation schedule.
  EOT
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major (or major.minor) version. Major-only lets AWS pick the latest supported minor."
  type        = string
  default     = "16"
}

variable "parameter_group_family" {
  description = "RDS parameter-group family, e.g. postgres16. Must match engine_version's major."
  type        = string
  default     = "postgres16"
}

variable "instance_class" {
  description = "Instance class. Graviton (t4g/m6g) for ~20% lower cost at equal performance."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GB. 20 is the practical floor; storage autoscales up to max_allocated_storage."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "gp3 RDS storage starts at 20 GB."
  }
}

variable "max_allocated_storage" {
  description = <<-EOT
    Storage-autoscaling ceiling in GB. Above allocated_storage, RDS grows the
    volume on demand up to this bound — so a growing corpus does not hit
    ENOSPC, while the ceiling stops runaway cost. Set equal to allocated_storage
    to disable autoscaling.
  EOT
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database created on first boot, e.g. xbrl_db."
  type        = string
}

variable "master_username" {
  description = "Master user. NOT a reserved word (postgres/admin/root are rejected by RDS)."
  type        = string
  default     = "arag_admin"
}

variable "backup_retention_days" {
  description = "Automated-backup retention. >0 also enables point-in-time recovery. dev keeps a short window; prod lengthens it."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be 1-35 (0 would disable backups and PITR, which this module does not allow)."
  }
}

variable "backup_window" {
  description = "UTC daily backup window. Before the maintenance window, both off business hours."
  type        = string
  default     = "07:00-08:00"
}

variable "maintenance_window" {
  description = "UTC weekly maintenance window, after the backup window."
  type        = string
  default     = "sun:08:30-sun:09:30"
}

variable "multi_az" {
  description = "Multi-AZ standby. false in dev (cost); prod sets true for stateful HA."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Block DeleteDBInstance. false in dev (teardown is routine); prod sets true."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = <<-EOT
    Skip the final snapshot on destroy. true in dev is acceptable ONLY because the
    database is derived, rebuildable state: facts and MVs are re-ingested from the
    durable S3 filings, so a lost dev DB costs a re-ingest, not data. prod sets
    false and takes a final snapshot.
  EOT
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Performance Insights. Off in dev (the 7-day free tier still adds moving parts); enable on a real perf question."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention for the exported PostgreSQL log group. Never the never-expire default."
  type        = number
  default     = 7
}

variable "apply_immediately" {
  description = "Apply modifications at once rather than in the maintenance window. true in dev for fast iteration."
  type        = bool
  default     = true
}

variable "extra_parameters" {
  description = "Additional DB parameters beyond the TLS enforcement this module always sets."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

variable "start_cron" {
  description = <<-EOT
    Cron for starting the instance, in EventBridge Scheduler's 6-field format
    (minute hour day-of-month month day-of-week year), or null (default) for no
    schedule — a database does not acquire a nightly shutdown by upgrading this
    module.

    BRACKET the consuming app's window rather than matching it. RDS takes several
    minutes to reach `available`, so a database starting at the same minute as its
    app tier turns the first queries into connection errors; start before, stop
    after.

    May be null WHILE stop_cron is set — that is the PARKED configuration, and it
    is the only correct way to hold a database off for weeks. RDS force-starts a
    stopped instance after seven days, so parking is not "stop it and disable the
    schedules": that brings the database back on day 8 to bill 24x7 unnoticed. A
    recurring stop with no start re-parks it within a day, every time.

    Note day-of-week and day-of-month are mutually exclusive — one must be "?".
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.start_cron == null || length(split(" ", coalesce(var.start_cron, " "))) == 6
    error_message = "start_cron must have 6 fields (minute hour day-of-month month day-of-week year); the 5-field Unix form is rejected by EventBridge Scheduler."
  }
}

variable "stop_cron" {
  description = <<-EOT
    Cron for stopping the instance. Same 6-field format as start_cron.

    REQUIRED whenever either cron is set. The asymmetry is deliberate: a start
    with no stop bills 24x7 and is rejected at plan time, whereas a stop with no
    start is the parked configuration (see start_cron).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.stop_cron == null || length(split(" ", coalesce(var.stop_cron, " "))) == 6
    error_message = "stop_cron must have 6 fields (minute hour day-of-month month day-of-week year); the 5-field Unix form is rejected by EventBridge Scheduler."
  }
}

variable "schedule_timezone" {
  description = <<-EOT
    IANA timezone the crons are evaluated in. An IANA name rather than a fixed UTC
    offset so daylight saving is handled by AWS — "America/New_York" holds 21:10
    local across the DST boundary where "UTC-4" drifts an hour twice a year.
  EOT
  type        = string
  default     = "UTC"

  validation {
    condition     = can(regex("^[A-Za-z]+/[A-Za-z_+-]+$|^UTC$", var.schedule_timezone))
    error_message = "schedule_timezone must be an IANA name such as America/New_York, or UTC."
  }
}

variable "schedule_enabled" {
  description = <<-EOT
    Whether the schedules are active. false keeps the database running
    continuously without destroying the schedules — useful for an overnight job.

    Note this disables BOTH rules: a one-off "leave it up tonight" left here also
    cancels every future stop, so the database silently returns to 24x7 billing.

    NOT the way to park a database for weeks — for that leave this true and set
    start_cron to null, so the recurring stop survives to undo RDS's seven-day
    force-start. Disabling the schedules cancels that stop too.
  EOT
  type        = bool
  default     = true
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    Permissions boundary attached to the scheduler role. Required when start_cron
    and stop_cron are set (the exec role may only create roles that carry it), and
    unused otherwise.

    The boundary must allow rds:StartDBInstance/StopDBInstance on this instance or
    the role is capped to nothing and the schedule fires, reports success, and
    changes nothing.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
