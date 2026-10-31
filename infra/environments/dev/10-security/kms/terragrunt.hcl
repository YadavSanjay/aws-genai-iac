# dev / 10-security/kms — shared customer-managed key for data at rest.
#
# Step 2 of the rollout. Precedes 20-data because every encrypted store
# downstream references this key's alias.
#
# Cost: ~$1/month (one CMK). The first always-on charge in the estate.
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
}

terraform {
  source = "${get_repo_root()}/infra/modules/security/kms"
}

inputs = {
  name_prefix = local.env.name_prefix
  account_id  = local.merged.account_id
  region      = local.merged.region

  # dev: short recovery window, since teardown should be cheap and there is no
  # data worth a 30-day grace period. prod must raise this.
  deletion_window_days = 7

  # Required before VPC flow logs can write to the SSE-KMS log archive. Without
  # it AWS reports the flow log as active and silently delivers nothing.
  allow_aws_log_delivery = true
}
