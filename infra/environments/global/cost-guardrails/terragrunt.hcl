# global / cost-guardrails — account-wide budget + Cost Anomaly Detection.
#
# FIRST component applied after the IAM baseline, and deliberately so: the
# provisioning principles require a budget and alarm to exist before the first
# meaningful spend. Costs ~$0/month itself.
#
# Account-global, not per-environment: a single account has one bill. Per-env
# tag-filtered budgets can be added under `<env>/91-cost` once dev/staging/prod
# actually carry distinguishable spend.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # alert_emails are personal addresses and live ONLY in the gitignored
  # account.local.hcl override — never in a committed file.
  # `try`, not a ternary — see the note in infra/root.hcl.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})
  merged             = merge(local.account, local.account_local)
}

terraform {
  source = "${get_repo_root()}/infra/modules/cost/budgets"
}

inputs = {
  name_prefix        = local.env.name_prefix
  monthly_budget_usd = local.merged.monthly_budget_usd

  # Fails validation if absent — a budget nobody is told about is not a guardrail.
  alert_emails = try(local.merged.cost_alert_emails, [])
}
