# dev / 90-observability/alerts — the operational alert channel (O1).
#
# First component of the 90-observability layer, and it lands first for the same
# reason cost-guardrails leads the account: an alarm with nowhere to publish is
# not detection, so the channel exists before the first alarm.
#
# The incident that motivated it: `genai-dev-qdrant-stop` fired on 2026-07-27,
# the EC2 call was refused, AWS recorded it in AWS/Scheduler TargetErrorCount —
# and the host ran overnight for two nights before anyone noticed. Every part of
# that failure was visible in CloudWatch at the time. Nothing was watching.
#
# Per-environment, unlike the account-global cost topic: dev alert noise must not
# train anyone to ignore the channel that will one day carry prod.
#
# Cost: $0 (SNS free tier covers this by orders of magnitude).
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # `try`, not a ternary — see the note in infra/root.hcl.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})
  merged             = merge(local.account, local.account_local)

  # Falls back to the cost-alert addresses so a fresh clone with only the existing
  # override file still gets a working channel; set ops_alert_emails in
  # account.local.hcl to route operational alerts somewhere else. Both live ONLY
  # in that gitignored file — never in a committed one.
  alert_emails = try(
    local.merged.ops_alert_emails,
    try(local.merged.cost_alert_emails, [])
  )
}

terraform {
  source = "${get_repo_root()}/infra/modules/observability/alerts"
}

inputs = {
  name_prefix = local.env.name_prefix

  # Fails validation if empty — a topic nobody is told about is not detection.
  alert_emails = local.alert_emails
}
