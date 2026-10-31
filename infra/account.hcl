# Single-account settings shared by ALL environments.
# Read by infra/root.hcl. Contains NO real account id — the real value
# lives in the gitignored infra/account.local.hcl and is merged over these.
locals {
  account_id = "000000000000" # placeholder — real id in account.local.hcl (gitignored)
  region     = "us-east-1"

  # Remote state backend (created once by scripts/bootstrap-backend.sh).
  # Locking is S3-native (`use_lockfile` in root.hcl) — no DynamoDB table.
  state_bucket = "aws-genai-iac-tfstate"

  # Account-wide monthly cost ceiling, in USD. Drives global/cost-guardrails:
  # alerts at 50/80/100% of ACTUAL spend and at 100% of FORECASTED month-end
  # spend. Sized to the projected dev steady state (~$125/mo with Graviton and
  # off-hours scheduling), so a breach means something is genuinely wrong.
  # Not a hard cap — AWS does not stop spend at a budget; it tells you.
  monthly_budget_usd = 150

  # cost_alert_emails is NOT set here — personal addresses are supplied by the
  # gitignored infra/account.local.hcl. Absent it, the module fails validation.
}
