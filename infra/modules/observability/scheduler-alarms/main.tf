# Alarms on EventBridge Scheduler's own health.
#
# Every scheduled start and stop in this estate — the NAT, Qdrant, MacroRAG, ARag
# and its database, Faultline — is an unattended API call made at an hour
# nobody is watching. When one fails it fails QUIETLY: Scheduler reports the
# invocation, the target refuses it, and the only evidence is a metric nobody
# reads. The host runs all night and the first symptom is the bill.
#
# That is not hypothetical. On 2026-07-27 `genai-dev-qdrant-stop` fired, the EC2
# call was refused, and TargetErrorCount recorded exactly one error. It took two
# days and a manual investigation to establish that much.
#
# Two distinct failures, so two alarms:
#
#   TargetErrorCount     the target refused the call — denied by IAM, a stale
#                        instance id, a malformed input, or a resource in a state
#                        that cannot accept the action.
#   InvocationDroppedCount
#                        retries were exhausted and the invocation was abandoned.
#                        With no DLQ configured this is the LAST trace of it; a
#                        start that dropped means a host that never came up.
#
# NOT alarmed on: "the schedule never fired at all". Scheduler's metrics carry a
# ScheduleGroup dimension, not a ScheduleName one, so a per-schedule silence
# check would have to infer expected counts per minute-of-day and would be noisy
# and wrong at DST boundaries. The honest gap is recorded in the README.
#
# Cost: $0.10 per alarm per month, so $0.20. Both are standard-resolution.

locals {
  # Alarms are named for what BROKE, not for the metric, so a notification subject
  # line reads as a problem statement.
  error_alarm_name   = "${var.name_prefix}-schedules-target-errors"
  dropped_alarm_name = "${var.name_prefix}-schedules-invocations-dropped"
}

resource "aws_cloudwatch_metric_alarm" "target_errors" {
  alarm_name        = local.error_alarm_name
  alarm_description = <<-EOT
    An EventBridge Scheduler invocation was REFUSED by its target in ${var.schedule_group}.

    The schedule fired correctly; the API call it made was rejected. Usual causes,
    most likely first: the scheduler role is capped by the app permissions boundary
    (the boundary must allow the action for the resource type — this is what broke
    RDS scheduling until RuntimeDatabaseScheduling was added); the target input
    names a resource that no longer exists (a replaced instance orphans a schedule
    held in a separate component); or the resource was in a state that cannot
    accept the action (an RDS start against a still-stopping instance).

    Diagnose without waiting for the next tick: simulate_principal_policy against
    the scheduler role and the live resource ARN, then fire-test by shifting the
    cron a few minutes out. See docs/runbooks/day2-operations.md.
  EOT

  namespace   = "AWS/Scheduler"
  metric_name = "TargetErrorCount"
  dimensions  = { ScheduleGroup = var.schedule_group }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # No data means no invocations were attempted in the window, which is the normal
  # state for all but a few minutes a day. Treating it as breaching would page
  # continuously; treating it as missing would leave the alarm INSUFFICIENT_DATA
  # forever and hide a real transition.
  treat_missing_data = "notBreaching"

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]

  tags = merge(var.tags, {
    Name = local.error_alarm_name
    Tier = "observability"
  })
}

resource "aws_cloudwatch_metric_alarm" "invocations_dropped" {
  alarm_name        = local.dropped_alarm_name
  alarm_description = <<-EOT
    An EventBridge Scheduler invocation in ${var.schedule_group} was DROPPED after
    exhausting its retries.

    Worse than a single target error: the action has been abandoned entirely and
    will not be retried before the next day's tick. A dropped START means a host
    that never came up; a dropped STOP means one that bills all night.

    No dead-letter queue is configured on these schedules, so this alarm is the
    only surviving record. Check the target's retry_policy — a stop allows 3
    attempts over 15 minutes, a start 10 over an hour.
  EOT

  namespace   = "AWS/Scheduler"
  metric_name = "InvocationDroppedCount"
  dimensions  = { ScheduleGroup = var.schedule_group }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]

  tags = merge(var.tags, {
    Name = local.dropped_alarm_name
    Tier = "observability"
  })
}
