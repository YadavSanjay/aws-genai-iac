# global / iam-baseline — Terraform execution role + permissions boundary.
#
# BOOTSTRAP ORDER (see docs/runbooks/terraform-execution-role.md):
#   1. An admin runs scripts/bootstrap-backend.sh (creates the S3 state bucket;
#      locking is S3-native, so there is no lock table).
#   2. That SAME admin applies THIS component once (the exec role does not exist
#      yet, so it cannot create itself). Do NOT set an assume_role provider here.
#   3. Every other component is then applied AS the exec role.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  # Real account id + trusted assume-role principals live in the gitignored
  # account.local.hcl override (merged over account.hcl by the root config).
  # `try`, not a ternary — see the note in infra/root.hcl.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})
  merged             = merge(local.account, local.account_local)
}

terraform {
  source = "${get_repo_root()}/infra/modules/security/iam-terraform-role"
}

inputs = {
  name_prefix  = local.env.name_prefix
  account_id   = local.merged.account_id
  region       = local.merged.region
  state_bucket = local.merged.state_bucket

  # Principals that may assume the exec role. Prefer an IAM Identity Center
  # permission-set role ARN or a thin tfuser ARN. Add `terraform_trusted_arns`
  # to account.local.hcl. Because the tfuser below is auto-added to the trust in
  # assume-role mode, an empty list yields a tfuser-only trust (NOT account root);
  # root is used only when there is neither an explicit principal nor a tfuser.
  trusted_principal_arns = try(local.merged.terraform_trusted_arns, [])
  require_mfa            = false

  # Dedicated Terraform IAM user. assume-role mode (recommended): tfuser only
  # assumes the exec role, so its keys carry no standing power. Switch to
  # "direct-attach" for the simplest `--profile tfuser` flow at the cost of
  # long-lived keys holding the full scoped permission set.
  create_terraform_user = true
  terraform_user_name   = "tfuser"
  user_access_mode      = "assume-role"
}
