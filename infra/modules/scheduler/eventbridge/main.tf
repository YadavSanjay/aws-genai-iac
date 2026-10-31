# Scheduled instance start/stop via EventBridge Scheduler.
#
# EventBridge Scheduler rather than a Lambda: the universal target calls the EC2
# API directly, so there is no function to write, package, patch or pay for. The
# schedules themselves cost $1.00 per million invocations — 60 a month here,
# which rounds to nothing.
#
# Stopping is the point. An EC2 instance genuinely stops billing compute, unlike
# a NAT Gateway, which is the entire reason the NAT is an instance (design §2a).

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  instance_arns = [
    for id in var.instance_ids :
    "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${id}"
  ]

  schedule_state = var.enabled ? "ENABLED" : "DISABLED"

  # Names are keyed on workload so the module can be instantiated more than once
  # in an environment (e.g. the NAT on 10-22 and Qdrant on 11-21) without the
  # role/schedule names colliding. Defaults to "instance" so existing callers
  # keep their current names.
  name = "${var.name_prefix}-${var.workload}"
}

# --- Role the scheduler assumes ----------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Confused-deputy gate. Without it, any EventBridge schedule in any account
    # could ask to assume this role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.name}-scheduler"
  description          = "EventBridge Scheduler: start/stop scheduled instances."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn

  tags = var.tags
}

# Scoped to the specific instance ARNs, not "*". The permissions boundary also
# tag-scopes these actions, so this is the narrower of two independent limits.
data "aws_iam_policy_document" "scheduler" {
  statement {
    sid    = "StartStopScheduledInstances"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = local.instance_arns
  }

  # Two distinct KMS needs, both on the same CMK, both required for a scheduled
  # start to actually work:
  #
  # 1. Decrypt the KMS-encrypted target INPUT at invocation time. Without it the
  #    schedule fires but Scheduler cannot decrypt its own input, so the EC2 call
  #    never happens.
  # 2. Decrypt the target instance's CMK-encrypted EBS VOLUMES at start. When EC2
  #    starts an instance on behalf of this role, it must Decrypt + GenerateDataKey
  #    + ReEncrypt + DescribeKey the volume in THIS role's context (a manual admin
  #    start works only because admin holds kms:*). Missing these, the instance
  #    launches then AWS stops it seconds later with `Client.InvalidKMSKey` — the
  #    schedule looks like it "didn't fire" when it did.
  #
  # NO kms:ViaService condition. Scheduler calls kms:Decrypt DIRECTLY from its own
  # execution environment (CloudTrail: eventSource kms.amazonaws.com, no ViaService
  # context), so a ViaService condition never matches. The key policy permits this
  # principal via its IAM-delegation statement; scoping to the one key ARN on a
  # single-purpose role is the least-privilege bound. Every action here is also
  # capped by the app permissions boundary, which must allow the same set.
  statement {
    sid    = "UseCmkForScheduleInputAndVolumes"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = [var.kms_key_arn]
  }

  # CreateGrant is how EC2 registers the per-volume grant it needs to decrypt an
  # encrypted EBS volume at start. Gated to AWS-service grants so it cannot be
  # used to delegate the key to an arbitrary principal.
  statement {
    sid       = "CreateGrantForEncryptedVolumes"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = [var.kms_key_arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-stop"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# --- Schedules ---------------------------------------------------------------

resource "aws_scheduler_schedule" "stop" {
  name       = "${local.name}-stop"
  group_name = "default"
  state      = local.schedule_state

  schedule_expression          = "cron(${var.stop_cron})"
  schedule_expression_timezone = var.timezone
  kms_key_arn                  = var.kms_key_arn

  # OFF, not a window. A flexible window would let the stop drift by up to the
  # window length, which blurs exactly the boundary we are billing against.
  flexible_time_window {
    mode = "OFF"
  }

  target {
    # Universal target: calls the EC2 API directly, no Lambda in between.
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = var.instance_ids
    })

    retry_policy {
      # A missed stop costs a few hours of compute, not correctness, and the
      # next day's schedule will catch it. Retrying for hours would risk
      # stopping the instance long after the window.
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 300
    }
  }
}

resource "aws_scheduler_schedule" "start" {
  name       = "${local.name}-start"
  group_name = "default"
  state      = local.schedule_state

  schedule_expression          = "cron(${var.start_cron})"
  schedule_expression_timezone = var.timezone
  kms_key_arn                  = var.kms_key_arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      InstanceIds = var.instance_ids
    })

    retry_policy {
      # A missed START is worse than a missed stop — it means no egress all day.
      # Retry harder and for longer.
      maximum_retry_attempts       = 10
      maximum_event_age_in_seconds = 3600
    }
  }
}
