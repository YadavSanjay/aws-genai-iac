# observability/alerts

The SNS topic every CloudWatch alarm in an environment publishes to.

## Purpose

One operational alert channel per environment, with a least-privilege topic
policy and confirmed email subscribers. Alarms live in their own components and
reference `topic_arn`.

Separate from the cost-alerts topic in `cost/budgets`: that one is account-global
and carries spend thresholds a human reads at leisure, this one carries "something
is broken right now" and is per-environment, so dev noise never trains anyone to
ignore a prod page.

**Why it exists.** A scheduled stop failed on 2026-07-27, AWS recorded the error
in `AWS/Scheduler` `TargetErrorCount`, and nobody found out for two days. The
infrastructure was fine; the detection was missing.

## Inputs (selected)

| Input | Default | Notes |
|---|---|---|
| `name_prefix` | — | Topic is `<prefix>-ops-alerts`. |
| `alert_emails` | — | Validated non-empty. Personal addresses → gitignored `account.local.hcl`. |
| `kms_master_key_id` | `alias/aws/sns` | See the warning below before changing. |

## Outputs

`topic_arn` (what alarms set as `alarm_actions`), `topic_name`, `subscribed_emails`.

## Security posture

- **Encrypted at rest** with the AWS-managed SNS key.
- **Publish restricted to `cloudwatch.amazonaws.com`**, confused-deputy gated on
  `aws:SourceAccount` so another account's alarm cannot publish here.
- **TLS enforced** — `SNS:Publish`/`Subscribe` denied when `aws:SecureTransport`
  is false.
- **No IAM principal is granted publish.** Alarms publish as a service; nothing in
  the estate needs a human or role publishing to this topic.

### Deliberately relaxed: AWS-managed key, not the project CMK

Same carve-out as `cost/budgets` ("AWS-managed only for low-value/ephemeral" — the
payload is an alarm name and a metric value, never secret or customer data), plus a
sharper reason specific to this topic: a CMK-encrypted topic requires every
publishing principal to hold `kms:GenerateDataKey*`/`Decrypt` on that key, and
CloudWatch publishes as a service principal. A missing grant means the alarm fires,
the publish is denied, and no notification arrives — reproducing exactly the silent
failure this component exists to eliminate. Compensating control: the topic policy
is least-privilege and TLS-only, and the post-apply test asserts both.

## Cost profile

$0 in practice. SNS bills nothing for the first million requests a month and email
notifications are free; a handful of alarm notifications rounds to zero. Alarms are
billed per alarm in their own components, not here.

## Gotcha

Email subscriptions require an out-of-band confirmation click. Terraform reports
them created while still `PendingConfirmation`, so an apply-only check would call a
channel healthy that delivers nothing. The post-apply test asserts the **confirmed**
count.
