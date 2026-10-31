# data/rds

PostgreSQL on Amazon RDS. Built for XbrlRag's `xbrl_db` (facts, registries,
materialized views, `audit` schema), but subsystem-agnostic.

## Purpose

A single private, encrypted PostgreSQL instance with its DB subnet group, a
TLS-enforcing parameter group, and a retention-bounded encrypted log group. The
master password is handled by AWS (managed rotating secret), never by Terraform.

## Inputs (selected)

| Input | Default | Notes |
|---|---|---|
| `name` | — | Identifier + base name (e.g. `genai-dev-arag`). |
| `subnet_ids` | — | ≥2 private subnets (RDS requires 2 AZs even single-AZ). |
| `vpc_security_group_ids` | — | The `rds` group from `networking/security-groups`; ingress is wired there. |
| `kms_key_arn` | — | CMK for storage, the managed secret, and the log group. |
| `engine_version` / `parameter_group_family` | `16` / `postgres16` | Major-only lets AWS pick the minor. |
| `instance_class` | `db.t4g.micro` | Graviton. |
| `allocated_storage` / `max_allocated_storage` | `20` / `100` | gp3, autoscaling to the ceiling. |
| `db_name` / `master_username` | — / `arag_admin` | `master_username` must not be a reserved word. |
| `backup_retention_days` | `7` | >0, so PITR is on. |
| `multi_az` / `deletion_protection` / `skip_final_snapshot` | `false` / `false` / `true` | Dev posture; flip for prod. |
| `start_cron` / `stop_cron` | `null` / `null` | 6-field Scheduler crons. Unset means 24×7. `stop_cron` alone = parked; `start_cron` alone is rejected. |
| `schedule_timezone` / `schedule_enabled` | `UTC` / `true` | IANA name, not an offset. |
| `permissions_boundary_arn` | `""` | Required when scheduling — the exec role only creates bounded roles. |

## Outputs

`endpoint`, `address`, `port`, `db_name`, `instance_arn`, `master_user_secret_arn`
(the managed credential — consumers grant `GetSecretValue` on it), plus the
subnet-group, parameter-group and log-group names, and — when scheduled —
`scheduler_role_arn`, `start_schedule_name`, `stop_schedule_name` and
`schedule_summary`.

## Scheduled stop/start (opt-in)

Setting `start_cron` + `stop_cron` adds two EventBridge Scheduler rules and a
role scoped to this one instance. Off by default: a database does not acquire a
nightly shutdown by upgrading the module.

**The schedule lives here, in the same module as the instance.** A sibling
`*-schedule` component would hold a *copy* of the identifier and rot; here the
target is a reference, so Terraform rewrites it in the same apply that changes
the instance. A stale schedule fails silently — it fires, reports success, and
nothing starts.

Things worth knowing before turning it on:

- **Bracket the consumer's window, don't match it.** RDS takes several minutes to
  reach `available`. An app tier starting the same minute as its database gets
  connection errors on its first queries.
- **The boundary must allow it.** Every role Terraform creates carries the app
  permissions boundary; without `rds:StartDBInstance`/`StopDBInstance` there the
  role is capped to nothing and the schedule silently no-ops. The boundary scopes
  those actions to the project name prefix; this module's own policy narrows them
  further to this instance's ARN.
- **Less KMS than the EC2 equivalent, deliberately.** The role gets `kms:Decrypt`
  only for the schedule's encrypted target input. RDS decrypts its own storage
  under a standing service grant created at instance creation, so the caller never
  touches the storage key — unlike an EC2 start, where the CMK-encrypted volume is
  decrypted in the caller's context and a missing grant means `Client.InvalidKMSKey`.
- **A stopped instance is auto-started by AWS after 7 days.** Harmless with a daily
  start; relevant if you disable the schedule while stopped.
- **`schedule_enabled = false` disables BOTH rules.** A one-off "keep it up
  tonight" left in place also cancels every future stop.

### Parking a database for weeks (`stop_cron` alone)

Set `stop_cron` and leave `start_cron` null. The module then creates the stop
rule and no start rule, and the plan is accepted — the crons are deliberately
**not** symmetric:

| Configuration | Result |
|---|---|
| start + stop | Normal daily window. |
| stop only | **Parked.** Nothing starts it; the recurring stop re-parks it. |
| start only | Rejected at plan time — it would bill 24×7. |

This is the only correct way to hold a database off for more than a week.
`schedule_enabled = false` is *not* it: that cancels the stop as well, so AWS's
seven-day force-start brings the database back and it then bills 24×7 with no
rule left to put it down. With a stop-only schedule the worst case is bounded at
a few hours once a week, and a manual `aws rds start-db-instance` still works for
off-window use.
- **Off-window work needs a manual start** (`aws rds start-db-instance`).

## Security posture

- **Encrypted at rest** with the project CMK (storage, the managed master-user
  secret, and the exported log group all under the one key policy).
- **TLS enforced in the engine** via `rds.force_ssl=1`, not only at the SG — a
  plaintext connection is rejected by the server.
- **No password in state**: `manage_master_user_password` keeps the credential in
  an AWS-managed, CMK-encrypted, rotating Secrets Manager secret.
- **Private only**: `publicly_accessible=false`, private subnet group, and ingress
  is SG-to-SG (5432 from the app + ingest tiers), wired in
  `networking/security-groups` — this module never opens the port.
- **Logging on**: the `postgresql` log ships to a group with explicit retention.

### Deliberately relaxed in dev (each has a variable and a written rationale)

Single-AZ (`multi_az`), no deletion protection, no enhanced monitoring, no
Performance Insights, password auth (not RDS IAM auth), and `skip_final_snapshot`.
The last is safe *because the database is derived state* — facts and MVs are
re-ingested from the durable S3 filings, so a lost dev DB costs a re-ingest, not
data. Prod flips these via the corresponding inputs.

## Cost profile

`db.t4g.micro` single-AZ ≈ $11.70/mo running 24×7 ($0.016/hr), ≈ $5.05/mo on a
~10.3 h/day schedule — about **-$6.65/mo**. 20 GB gp3 ≈ $2.30/mo and backups
within the free allowance at this size, both of which bill **whether the instance
is up or not**: stopping halves the line, it does not zero it. Storage autoscales
to `max_allocated_storage`, which bounds the worst case. The schedules themselves
are ~60 invocations/month, well under a cent.
