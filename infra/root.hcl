# Root Terragrunt configuration.
# Single AWS account; one S3 state bucket with an isolated key per component.
# Included by every environment component via:
#   include "root" { path = find_in_parent_folders("root.hcl") }
# Named root.hcl, NOT terragrunt.hcl: a root file named terragrunt.hcl is a
# deprecated Terragrunt anti-pattern (it collides with component configs of the
# same name) and errors in a future release.

locals {
  # Committed base (placeholders only — no real account id).
  account_base = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals

  # State key MUST be OS-independent. On Windows path_relative_to_include()
  # returns backslashes, which S3 keeps as literal key characters — a POSIX
  # shell or CI runner would then compute a *different* key, miss the existing
  # state, and try to recreate everything. Normalize to forward slashes.
  state_key = "${replace(path_relative_to_include(), "\\", "/")}/terraform.tfstate"

  # Real account values live in the GITIGNORED infra/account.local.hcl override.
  # find_in_parent_folders returns "" when absent, so CI without the override
  # falls back cleanly to the committed placeholders.
  # NOTE: a `path == "" ? {} : read_terragrunt_config(path).locals` ternary looks
  # equivalent but does NOT work — HCL type-checks both branches, and the empty
  # object is not type-consistent with the populated one, so it fails with
  # "Inconsistent conditional result types" even when the file is present.
  # `try` short-circuits on the read error instead of unifying types.
  account_local_path = find_in_parent_folders("account.local.hcl", "")
  account_local      = try(read_terragrunt_config(local.account_local_path).locals, {})

  account = merge(local.account_base, local.account_local)
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

# --- Remote state: one bucket, per-component key derived from the folder path ---
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket = local.account.state_bucket
    key    = local.state_key
    region = local.account.region

    encrypt = true

    # S3-native locking (a conditional-write `<key>.tflock` object) instead of a
    # DynamoDB table. `dynamodb_table` is deprecated in the S3 backend. The exec
    # role needs no new grants: its s3:PutObject/DeleteObject on the state bucket
    # already covers the lock object, and the app boundary's blanket s3:* deny on
    # this bucket keeps app roles away from it.
    use_lockfile = true
  }
}

# --- Provider generated for every component, with consistent default tags ---
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region              = "${local.account.region}"
  allowed_account_ids = ["${local.account.account_id}"]
  default_tags {
    tags = {
      Project     = "aws-genai-iac"
      Environment = "${local.env.name}"
      ManagedBy   = "terragrunt"
    }
  }
}
EOF
}

# Inputs common to every component; component terragrunt.hcl files add their own.
inputs = merge(local.account, local.env)
