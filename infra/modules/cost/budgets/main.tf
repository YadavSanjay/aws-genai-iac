# Account-wide cost guardrails: a monthly budget with tiered alerts, plus
# Cost Anomaly Detection. This is deliberately the FIRST component applied —
# per the provisioning principles, a budget and alarm exist before the first
# meaningful spend, not after the first surprising bill.
#
# Cost of this module itself: effectively $0. AWS Budgets bills $0.02/day beyond
# the first two budgets (we create one); Cost Anomaly Detection is free.

data "aws_caller_identity" "current" {}

locals {
  topic_name = "${var.name_prefix}-cost-alerts"
}

# --- Alert channel -----------------------------------------------------------
# Encrypted with the AWS-managed SNS key rather than a project CMK. Deliberate,
# per the "AWS-managed only for low-value/ephemeral" carve-out: this topic
# carries threshold notifications, never customer or secret data, and it must
# stand up BEFORE the KMS component exists (it is the first thing applied).
resource "aws_sns_topic" "cost_alerts" {
  name              = local.topic_name
  display_name      = "AWS cost alerts"
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Name = local.topic_name
  })
}

# Least-privilege publish rights for exactly the two AWS services that need
# them, each confused-deputy-gated on SourceAccount so another account's budget
# cannot publish into our topic.
data "aws_iam_policy_document" "cost_alerts" {
  statement {
    sid     = "AllowBudgetsPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.cost_alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid     = "AllowCostAnomalyPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }

    resources = [aws_sns_topic.cost_alerts.arn]

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

    resources = [aws_sns_topic.cost_alerts.arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "cost_alerts" {
  arn    = aws_sns_topic.cost_alerts.arn
  policy = data.aws_iam_policy_document.cost_alerts.json
}

# Email subscriptions require an out-of-band click to confirm. Terraform reports
# them created while still "pending confirmation" — the post-apply check asserts
# the confirmed count, because an unconfirmed subscription silently delivers
# nothing.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Monthly budget ----------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Exclude credits and refunds so the alert tracks real, payable spend.
  cost_types {
    include_credit             = false
    include_refund             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  dynamic "notification" {
    for_each = toset(var.actual_thresholds_percent)

    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
    }
  }

  # Forecast alerting is the one that gives you time to react — it fires when
  # AWS projects month-end spend to breach, not once it already has.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = var.forecast_threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]

  tags = var.tags
}

# --- Cost Anomaly Detection --------------------------------------------------
# Catches the failure mode a budget misses: one service spiking hard early in
# the month while the account total is still under the cap.
#
# AWS allows exactly ONE dimensional (SERVICE) monitor per account. Where the
# auto-created "Default-Services-Monitor" already exists this resource ADOPTS it
# by name (imported into state) rather than creating a second one — creating
# fails with "Limit exceeded on dimensional spend monitor creation", and
# renaming would force a replace that discards the trained baseline.
# See var.anomaly_monitor_name.
resource "aws_ce_anomaly_monitor" "services" {
  name              = var.anomaly_monitor_name
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"

  tags = var.tags
}

resource "aws_ce_anomaly_subscription" "services" {
  name      = "${var.name_prefix}-anomaly-alerts"
  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_impact_usd)]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]

  tags = var.tags
}
