# `cost/budgets` — account-wide cost guardrails

Monthly AWS Budget with tiered alerts, plus Cost Anomaly Detection, delivered to
an SNS topic with email subscribers.

**This is the first component applied to the account.** Per the provisioning
principles in the root `CLAUDE.md`, a budget and alarm exist *before* the first
meaningful spend. Applying it after the fact means the first thing it tells you
is what you already owe.

## Resources

| Resource | Purpose |
|---|---|
| `aws_sns_topic.cost_alerts` | Alert channel, reusable by later billing alarms |
| `aws_sns_topic_policy` | Scoped publish for Budgets + Cost Anomaly; TLS-only deny |
| `aws_sns_topic_subscription.email` | One per `alert_emails` entry |
| `aws_budgets_budget.monthly` | Account-wide COST budget, ACTUAL + FORECASTED alerts |
| `aws_ce_anomaly_monitor.services` | Per-service anomaly monitor (usually **adopted**, see below) |
| `aws_ce_anomaly_subscription.services` | Routes anomalies over the threshold to SNS |

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `name_prefix` | string | — | e.g. `genai` |
| `monthly_budget_usd` | number | — | Must be > 0 |
| `alert_emails` | list(string) | — | Must be non-empty and well-formed |
| `actual_thresholds_percent` | list(number) | `[50, 80, 100]` | Each in (0, 100] |
| `forecast_threshold_percent` | number | `100` | Fires on projected month-end breach |
| `anomaly_impact_usd` | number | `10` | Minimum absolute impact to alert |
| `tags` | map(string) | `{}` | Merged onto all resources |

## Outputs

`sns_topic_arn`, `sns_topic_name`, `budget_name`, `anomaly_monitor_arn`,
`pending_email_subscriptions`.

## The anomaly monitor is adopted, not created

AWS permits exactly **one dimensional (SERVICE) spend monitor per account**, and
most accounts already carry an auto-created `Default-Services-Monitor`. Creating
a second fails with `ValidationException: Limit exceeded on dimensional spend
monitor creation`.

This module therefore **adopts** the existing monitor: `anomaly_monitor_name`
defaults to `Default-Services-Monitor` and the resource is imported into state
rather than created.

```bash
terragrunt import aws_ce_anomaly_monitor.services \
  "arn:aws:ce::<acct>:anomalymonitor/<monitor-id>"
```

**Naming deviation, stated deliberately.** This breaks the
`<project>-<env>-<component>` convention. Renaming forces a replace, and anomaly
detection needs roughly ten days of history to baseline — a rename would discard
a trained model to satisfy a naming rule. The monitor is still fully under IaC
control (proven by the `ManagedBy=terragrunt` tag assertion in the test), which
is what the convention actually exists to guarantee.

On a greenfield account with no default monitor, set `anomaly_monitor_name` to
`"<prefix>-service-anomalies"` and let Terraform create it normally.

## Security posture

- **Least privilege** — the topic policy grants `SNS:Publish` to exactly
  `budgets.amazonaws.com` and `costalerts.amazonaws.com`, each gated on
  `aws:SourceAccount` to close the confused-deputy path. No wildcard principal
  holds publish rights.
- **In transit** — an explicit `Deny` on `SNS:Publish`/`SNS:Subscribe` when
  `aws:SecureTransport` is false.
- **At rest — deliberate relaxation.** The topic uses the AWS-managed
  `alias/aws/sns` key, not a project CMK. Two reasons: this component is applied
  *before* the KMS component exists (it is first by design), and the payload is
  threshold notifications only — never secret or customer data. This is the
  "AWS-managed only for low-value/ephemeral" carve-out. *Compensating control:*
  the topic policy above restricts publishers to two AWS services and
  subscribers are explicit email addresses, so there is no anonymous read path.
- **No sensitive identifiers committed** — `alert_emails` is supplied from the
  gitignored `infra/account.local.hcl`, never from a checked-in file.

## Cost profile

**~$0.00/month.**

| Line item | Rate | This module |
|---|---|---|
| AWS Budgets | First 2 budgets free, then $0.02/day | 1 budget → free |
| Cost Anomaly Detection | Free | free |
| SNS email notifications | First 1,000/month free | well under |

The module cannot meaningfully move the bill; its entire purpose is to bound
everything applied after it.

## Verification

`apply` success proves nothing here — a budget with an unconfirmed subscriber is
a budget that never tells anyone. See
`tests/integration/test_cost_guardrails.py`, which queries the live AWS API and
asserts the budget limit, both notification types, the anomaly threshold, and
**the confirmed (not merely created) subscription count**.

Each addressee must click the AWS confirmation email before alerts deliver.
Until then `ConfirmedSubscriptionsPending` is non-zero and the test fails —
which is the correct outcome, not a flake.
