# `scheduler/eventbridge` — scheduled instance start/stop

Stops and starts EC2 instances on a cron, in a named timezone.

Currently used for the NAT instance. The same module covers the app tier's
off-hours shutdown, and later the optional EOD batch schedules (Faultline
pricing/risk, XbrlRag MV refresh).

## Why EventBridge Scheduler rather than a Lambda

The **universal target** calls the EC2 API directly, so there is no function to
write, package, patch, or pay for — and no Lambda execution role to review. The
schedules cost $1.00 per million invocations; 60 a month rounds to nothing.

## Resources

| Resource | Purpose |
|---|---|
| `aws_scheduler_schedule.stop` | Stops the instances |
| `aws_scheduler_schedule.start` | Starts them |
| `aws_iam_role.scheduler` | Assumed by the scheduler; ARN-scoped |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `instance_ids` | list(string) | — | Validated as `i-...` |
| `timezone` | string | `UTC` | **IANA name** — see below |
| `start_cron` | string | `0 10 * * ? *` | 6-field EventBridge cron |
| `stop_cron` | string | `0 22 * * ? *` | |
| `enabled` | bool | `true` | False keeps instances up without deleting schedules |
| `permissions_boundary_arn` | string | — | Required by the exec role |
| `tags` | map(string) | `{}` | |

## Outputs

`role_arn`, `stop_schedule_name`, `start_schedule_name`, `schedule_summary`.

## The timezone is load-bearing

Get it wrong and the instance is stopped during working hours.

Use an **IANA name**, never a fixed offset. `America/New_York` keeps 22:00 local
across the daylight-saving boundary; `UTC-4` would silently drift by an hour
twice a year — and the symptom would be "the environment goes down an hour early
in November", which is a miserable thing to debug.

EventBridge Scheduler evaluates `schedule_expression_timezone` natively, so DST
is handled by AWS rather than by us.

### Cron format

Six fields: `minute hour day-of-month month day-of-week year`. Day-of-month and
day-of-week are **mutually exclusive** — one must be `?`. `0 22 * * ? *` is
22:00 every day.

## Security posture

- **`flexible_time_window` is OFF.** A window would let the stop drift by up to
  its length, blurring exactly the boundary being billed against.
- **The role's policy is ARN-scoped** to the specific instances, not `*`. The
  permissions boundary *also* tag-scopes these actions to
  `Project=aws-genai-iac`, so two independent limits apply and the narrower wins.
- **Confused-deputy gate** on the trust policy: `aws:SourceAccount` must match,
  so a schedule in another account cannot assume this role.
- **Start/stop only.** Deliberately not `RebootInstances` and never
  `TerminateInstances` — stopping is recoverable, terminating is not.

### Requires an app-boundary grant

Every role Terraform creates carries the app permissions boundary. Until
`RuntimeInstanceScheduling` was added to `security/iam-terraform-role`, that
boundary capped `ec2:StartInstances`/`StopInstances` away entirely — and the
failure is silent: the schedule fires successfully, reports success, changes
nothing, and shows up only on the bill.

## Retry policy is asymmetric, deliberately

A missed **stop** costs a few hours of compute and the next day's schedule
catches it — 3 attempts over 5 minutes.

A missed **start** means no egress for the whole working day — 10 attempts over
an hour.

Retrying a stop for hours would risk stopping the instance long after the
intended window, which is worse than missing it.

## Cost profile

| Line item | Rate | This module |
|---|---|---|
| EventBridge Scheduler invocations | $1.00 / million | 60/month → ~$0.00006 |

**The module costs nothing; what it saves is the point.** For the NAT instance
at 12 hours a day:

| | Always on | Scheduled |
|---|---|---|
| `t4g.nano` compute | $3.07 | $1.53 |
| Public IPv4 (released while stopped) | $3.60 | $1.80 |
| 8 GB gp3 root (billed while stopped) | $0.64 | $0.64 |
| **Total** | **$7.31/mo** | **~$3.97/mo** |

EBS is the floor — a stopped instance still pays for its volume. That is why the
root volume is 8 GB rather than a comfortable default.

## What breaks while stopped

**Private-subnet egress stops entirely.** That is the intent for dev, but it
means anything scheduled to run overnight in a private subnet cannot reach the
internet. If a nightly batch is added later, either its schedule must sit inside
the NAT's window or the NAT's window must widen to cover it.

The auto-assigned public IP is released on stop and a **new one is assigned on
start**. Harmless here — routes target the ENI, which persists — but it does
mean the egress address is not stable, so nothing may allowlist it.
