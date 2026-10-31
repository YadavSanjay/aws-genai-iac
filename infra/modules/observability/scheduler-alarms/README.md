# observability/scheduler-alarms

Alarms on EventBridge Scheduler's own health — the detection layer for every
scheduled start and stop in the estate.

## Purpose

Every schedule here is an unattended API call made at an hour nobody is watching,
and when one fails it fails quietly: Scheduler reports the invocation, the target
refuses it, and the only evidence is a metric nobody reads.

On **2026-07-27** `genai-dev-qdrant-stop` fired, the EC2 call was refused, and
`TargetErrorCount` recorded exactly one error. The host ran overnight, and it took
two days plus a manual investigation to establish that much. This module makes that
class of failure announce itself.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `name_prefix` | — | Alarms are `<prefix>-schedules-*`. |
| `alert_topic_arn` | — | From `observability/alerts`. Needs a **confirmed** subscriber. |
| `schedule_group` | `default` | Every schedule in this estate lives in the default group. |

## Outputs

`target_error_alarm_name`, `invocations_dropped_alarm_name`, `alarm_names`.

## What it watches

| Metric | Means | Typical cause |
|---|---|---|
| `TargetErrorCount` | The schedule fired; the target **refused** the call | Role capped by the app permissions boundary; stale target id; malformed target input; resource in a state that cannot accept the action |
| `InvocationDroppedCount` | Retries exhausted, invocation **abandoned** | The action will not happen before the next day's tick — a dropped start means a host that never came up |

Both use `Sum > 0` over 5 minutes with `treat_missing_data = "notBreaching"`: no
data means no invocations were attempted, which is the normal state for all but a
few minutes a day.

## Known gap — "the schedule never fired at all"

Not covered, deliberately. Scheduler's metrics carry a `ScheduleGroup` dimension,
not a `ScheduleName` one, so detecting *silence* would mean inferring expected
invocation counts per minute-of-day — noisy, and wrong at every DST boundary. A
schedule that is `DISABLED` (the usual reason for silence, e.g. a one-off overnight
override left in place) is better caught by the per-component post-apply tests,
which assert `State == "ENABLED"`.

The same dimension limit means an alarm cannot name the schedule that failed.
Attribute it by which schedules share that minute — the crons are in the
components — or give each workload its own schedule group later.

## Cost profile

$0.20/month — two standard-resolution alarms at $0.10 each. Notifications are free.
