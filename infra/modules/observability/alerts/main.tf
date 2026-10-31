# Operational alert channel — the SNS topic every CloudWatch alarm in the estate
# publishes to.
#
# Separate from the cost-alerts topic in cost/budgets, deliberately: that one is
# account-global and carries spend thresholds a human reads at leisure; this one
# carries "something is broken right now" and is per-environment, so dev noise
# never trains anyone to ignore a prod page.
#
# Why this exists at all: a scheduled stop failed on 2026-07-27, AWS recorded the
# error in AWS/Scheduler TargetErrorCount, and nobody found out for two days. The
# infrastructure was fine; the DETECTION was missing. A failure nothing reports is
# indistinguishable from success.
#
# Cost: SNS is $0 for the first million requests and email notifications are free.
# A handful of alarm notifications a month rounds to nothing; the alarms themselves
# are billed by the alarm, not by this topic.

data "aws_caller_identity" "current" {}

locals {
  topic_name = "${var.name_prefix}-ops-alerts"
}

# AWS-managed SNS key rather than the project CMK. This is the same carve-out
# cost/budgets took ("AWS-managed only for low-value/ephemeral"), and here there is
# a second, sharper reason: a CMK-encrypted topic requires every publishing
# principal to hold kms:GenerateDataKey*/Decrypt on that key, and CloudWatch alarms
# publish as a service principal. Get that grant wrong and the alarm fires, the
# publish is denied, and no notification arrives — reproducing precisely the silent
# failure this component exists to eliminate. The payload is an alarm name and a
# metric value, never secret or customer data.
resource "aws_sns_topic" "ops" {
  name              = local.topic_name
  display_name      = "${var.name_prefix} operational alerts"
  kms_master_key_id = var.kms_master_key_id

  tags = merge(var.tags, {
    Name = local.topic_name
    Tier = "observability"
  })
}

data "aws_iam_policy_document" "ops" {
  # CloudWatch alarms are the only publisher, and only from this account —
  # confused-deputy gated so another account's alarm cannot publish into it.
  statement {
    sid     = "AllowCloudWatchAlarmsPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    resources = [aws_sns_topic.ops.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # TLS-only, matching the in-transit rule applied to every other resource.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["SNS:Publish", "SNS:Subscribe"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [aws_sns_topic.ops.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "ops" {
  arn    = aws_sns_topic.ops.arn
  policy = data.aws_iam_policy_document.ops.json
}

# Email subscriptions need an out-of-band click. Terraform reports them created
# while they are still "pending confirmation", so an apply-only check would call
# a channel healthy that delivers nothing — the post-apply test asserts the
# CONFIRMED count instead.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = each.value
}
