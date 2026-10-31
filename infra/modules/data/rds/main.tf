# PostgreSQL on RDS — ARag's relational store (xbrl_db: facts, registries, MVs,
# audit). One always-on-capable data tier, so every default here leans to the
# cheap, private, encrypted end and the prod-hardening knobs are variables.
#
# Credential handling is the notable choice: manage_master_user_password puts the
# master password in an AWS-managed, CMK-encrypted, rotating Secrets Manager secret
# that Terraform NEVER sees — so the password is not in state, in a tfvar, or in
# this repo. Consumers read it from master_user_secret_arn (see outputs).

locals {
  # RDS writes the postgres log to this fixed path when the export is enabled;
  # pre-creating it lets us set retention + CMK instead of taking the never-expire,
  # AWS-managed-key default RDS would otherwise create.
  postgres_log_group = "/aws/rds/instance/${var.name}/postgresql"

  # Scheduling is opt-in: a database only acquires a nightly shutdown when a
  # caller asks for one.
  #
  # The two crons are NOT symmetric. A start with no stop bills forever and is
  # rejected (see the precondition below). A stop with no start is the PARKED
  # configuration and is deliberately allowed: RDS force-starts a stopped
  # instance after seven days, so an estate parked for a month needs a recurring
  # stop and no start at all. Without the recurring stop the database quietly
  # comes back on day 8 and then bills 24x7 for the rest of the park.
  schedule_requested = var.start_cron != null || var.stop_cron != null
  schedule_count     = local.schedule_requested ? 1 : 0
  start_count        = local.schedule_requested && var.start_cron != null ? 1 : 0
  schedule_name      = "${var.name}-db"
}

data "aws_caller_identity" "current" {}

# --- Networking placement -----------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "Private subnets for ${var.name}; RDS requires >=2 AZs even single-AZ."
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name}-subnets"
    Tier = "data"
  })
}

# --- Parameters: TLS is enforced in the engine, not just the SG ---------------

resource "aws_db_parameter_group" "this" {
  name        = var.name
  family      = var.parameter_group_family
  description = "${var.name}: force TLS on every connection."

  # rds.force_ssl=1 makes the server REJECT any non-TLS connection. Belt to the
  # SG's braces: the network path is already private, but this guarantees no
  # client (or misconfigured DSN) ever speaks plaintext to the database.
  #
  # pending-reboot, not immediate: rds.force_ssl is a STATIC parameter, so RDS
  # records it that way whatever is asked for. Declaring "immediate" produced a
  # diff on every single plan for the life of the instance — the state said one
  # thing and AWS said the other, forever. The value takes effect at the next
  # reboot, and for a scheduled database that is the same night.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  dynamic "parameter" {
    for_each = var.extra_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name}-params"
    Tier = "data"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Log export: retention + CMK set explicitly, not left to RDS --------------

resource "aws_cloudwatch_log_group" "postgres" {
  # ACCEPTED, DEV-RELAXED. CKV_AWS_338 wants >=1 year retention; dev keeps a short
  # window (var.log_retention_days, 7d) because these logs are for live debugging,
  # not long-term audit, and the account CloudTrail already retains the API trail.
  # The point checkov cares about — retention is SET, not the never-expire default —
  # is satisfied; prod lengthens the window via the same variable.
  #checkov:skip=CKV_AWS_338:Dev keeps short retention deliberately; var.log_retention_days lengthens it for prod
  name              = local.postgres_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.name}-postgresql"
    Tier = "data"
  })
}

# --- The instance -------------------------------------------------------------

resource "aws_db_instance" "this" {
  # ACCEPTED, DEV-RELAXED — each has a written rationale and a variable to flip in
  # prod, per the provisioning principles (silent relaxation is the defect).
  #
  # CKV_AWS_157 Multi-AZ: single-AZ in dev to halve compute; var.multi_az flips it.
  # CKV_AWS_293 deletion protection: off in dev (teardown is routine); var flips it.
  # CKV_AWS_118 enhanced monitoring: off in dev (per-instance charge); CloudWatch
  #   metrics + optional Performance Insights cover the dev need.
  # CKV_AWS_161 IAM DB auth: password auth via the managed, rotating secret for
  #   now; RDS IAM-auth tokens are a tracked follow-up (ARag plan §open items).
  # CKV_AWS_353/354 Performance Insights: off in dev; var.performance_insights_enabled
  #   turns it on and it is CMK-encrypted when it does.
  #checkov:skip=CKV_AWS_157:Single-AZ is the deliberate dev cost posture; var.multi_az flips it for prod
  #checkov:skip=CKV_AWS_293:Deletion protection off in dev by design; var.deletion_protection flips it
  #checkov:skip=CKV_AWS_118:Enhanced monitoring off in dev (per-instance cost); CloudWatch + PI cover it
  #checkov:skip=CKV_AWS_161:Password auth via managed rotating secret; RDS IAM auth is a tracked follow-up
  #checkov:skip=CKV_AWS_353:Performance Insights off in dev; var.performance_insights_enabled enables it
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Storage: gp3, encrypted with the project CMK, autoscaling to a bounded ceiling.
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = var.db_name
  username = var.master_username

  # Password lives in an AWS-managed, CMK-encrypted, rotating secret — never in
  # Terraform state. Consumers read master_user_secret_arn (outputs.tf).
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = var.vpc_security_group_ids
  publicly_accessible    = false

  backup_retention_period   = var.backup_retention_days
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = true
  delete_automated_backups  = true
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  multi_az                     = var.multi_az
  deletion_protection          = var.deletion_protection
  auto_minor_version_upgrade   = true
  apply_immediately            = var.apply_immediately
  performance_insights_enabled = var.performance_insights_enabled
  performance_insights_kms_key_id = (
    var.performance_insights_enabled ? var.kms_key_arn : null
  )

  # Ship the postgres log to the pre-created, retention-bounded, CMK-encrypted
  # group above rather than letting RDS mint a never-expiring one.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, {
    Name = var.name
    Tier = "data"
  })

  depends_on = [aws_cloudwatch_log_group.postgres]
}

# --- Scheduled stop/start -----------------------------------------------------
#
# IN THIS MODULE, not a separate *-schedule component, and that is the point: a
# schedule living elsewhere holds a COPY of this instance's identifier, which
# rots the moment the instance is renamed or replaced (a schedule pointing at a
# resource that no longer exists fails SILENTLY — it fires, reports success, and
# nothing starts). Here the target is a REFERENCE to aws_db_instance.this, so
# Terraform rewrites it in the same apply that changes the instance and the
# stale window never exists.
#
# EventBridge Scheduler's universal target calls the RDS API directly: no Lambda
# to write, package, patch or pay for. 60 invocations a month rounds to $0.
#
# What a stop actually saves: instance-hours. Storage, backups and the log group
# keep billing while stopped — this halves the line, it does not zero it. Two RDS
# behaviours worth knowing: a stopped instance is auto-STARTED by AWS after 7
# days (harmless here, the daily start beats it to it), and a stop is refused
# while a backup or modification is in progress, which is why the retry policy
# below is not zero.

data "aws_iam_policy_document" "scheduler_assume" {
  count = local.schedule_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy gate: without it, a schedule in any other account could ask
    # to assume this role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = local.schedule_count

  name                 = "${local.schedule_name}-scheduler"
  description          = "EventBridge Scheduler: stop and start ${var.name} on its daily window."
  assume_role_policy   = data.aws_iam_policy_document.scheduler_assume[0].json
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(var.tags, {
    Name = "${local.schedule_name}-scheduler"
    Tier = "data"
  })

  # Both preconditions fail the PLAN rather than producing a half-working
  # schedule that only misbehaves at 21:10.
  lifecycle {
    precondition {
      condition     = var.stop_cron != null
      error_message = "stop_cron is required whenever the database is scheduled: a start with no stop brings the database up and never puts it back down, billing 24x7. (The reverse — a stop with no start — is the parked configuration and is allowed.)"
    }

    precondition {
      condition     = can(regex("^arn:aws:iam::", var.permissions_boundary_arn))
      error_message = "permissions_boundary_arn is required when scheduling: the exec role may only create roles that carry the app boundary."
    }
  }
}

# Scoped to THIS instance's ARN, not the account's databases. The app permissions
# boundary independently caps the same actions to the project name prefix, so
# these are two independent limits, the narrower of which is this one.
#
# The KMS pair is for ONE thing: decrypting this schedule's own encrypted target
# input at invocation time. It is deliberately NOT the wider set the EC2
# scheduler role needs (GenerateDataKey/ReEncrypt/CreateGrant) — an EC2 start
# makes EC2 decrypt the CMK-encrypted EBS volume IN THE CALLER'S CONTEXT,
# whereas RDS decrypts its own storage under a standing service grant created at
# instance creation (grantee rds.<region>.amazonaws.com, retired by RDS itself).
# The caller never touches the storage key, so granting it would be over-grant.
data "aws_iam_policy_document" "scheduler" {
  count = local.schedule_count

  statement {
    sid    = "StartStopThisDatabase"
    effect = "Allow"
    actions = [
      "rds:StartDBInstance",
      "rds:StopDBInstance",
    ]
    resources = [aws_db_instance.this.arn]
  }

  statement {
    sid    = "DecryptScheduleInput"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = local.schedule_count

  name   = "start-stop"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

resource "aws_scheduler_schedule" "stop" {
  count = local.schedule_count

  name       = "${local.schedule_name}-stop"
  group_name = "default"
  state      = var.schedule_enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = "cron(${var.stop_cron})"
  schedule_expression_timezone = var.schedule_timezone
  kms_key_arn                  = var.kms_key_arn

  # OFF, not a window: a flexible window would blur the boundary being billed
  # against, and would risk stopping the database while its app tier is still up.
  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      DbInstanceIdentifier = aws_db_instance.this.identifier
    })

    retry_policy {
      # A stop refused because a backup is running is worth retrying for a few
      # minutes; retrying for hours would stop the database in the middle of the
      # next morning.
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 900
    }
  }
}

resource "aws_scheduler_schedule" "start" {
  count = local.start_count

  name       = "${local.schedule_name}-start"
  group_name = "default"
  state      = var.schedule_enabled ? "ENABLED" : "DISABLED"

  schedule_expression          = "cron(${var.start_cron})"
  schedule_expression_timezone = var.schedule_timezone
  kms_key_arn                  = var.kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      DbInstanceIdentifier = aws_db_instance.this.identifier
    })

    retry_policy {
      # A missed START is the worse failure: the app tier comes up on schedule
      # and every query fails against a database that is not there. Retry harder
      # and for longer than the stop.
      maximum_retry_attempts       = 10
      maximum_event_age_in_seconds = 3600
    }
  }
}
