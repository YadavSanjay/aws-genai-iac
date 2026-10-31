# dev / 20-data/logs-bucket — central log archive.
#
# Pulled AHEAD of 00-networking in the rollout, despite the numeric prefix. VPC
# flow logs need a destination bucket, and that bucket must be encrypted, private,
# TLS-only and lifecycled like any other. Building it here means the security
# posture is written once in infra/modules/data/s3, rather than duplicated inside
# the VPC module and then rewritten when 20-data arrives properly.
#
# Later consumers: ALB access logs, S3 server access logs.
#
# Cost: storage only (~$0.023/GB-month), no fixed charge. 90-day expiry keeps it
# bounded at roughly a few cents a month for dev flow-log volume.
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

dependency "kms" {
  config_path = "../../10-security/kms"

  # Lets `plan` work before the key exists (and in CI without state). The mock
  # is only ever used for planning — apply resolves the real output.
  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/data/s3"
}

inputs = {
  # MUST start with the "genai-" prefix: the exec role's s3 grant is ARN-scoped
  # to arn:aws:s3:::genai-* (see security/iam-terraform-role, GlobalData ->
  # ProjectBuckets). A bucket named outside that prefix fails CreateBucket with
  # AccessDenied — which is the scoping working, not a bug.
  #
  # The state bucket (aws-genai-iac-tfstate) predates this convention and is
  # covered by its own policy; everything provisioned since uses genai-*, e.g.
  # the KMS alias genai-dev-primary.
  #
  # Region suffix is for global uniqueness, not information: S3 names are
  # globally unique across all AWS accounts, and "genai-dev-logs" alone is
  # short enough to plausibly be taken by someone else.
  bucket_name = "genai-${local.env.name}-logs-${local.merged.region}"
  kms_key_arn = dependency.kms.outputs.key_arn

  # Log archive: short retention in dev. Raise deliberately in prod, where
  # retention is usually a compliance answer rather than a cost one.
  expiration_days            = 90
  noncurrent_expiration_days = 7

  # No transitions: STANDARD_IA bills a 30-day minimum, so moving objects that
  # only live 90 days saves pennies and adds a moving part.

  # Deliberately empty — this bucket IS the access-log target, and S3 does not
  # permit a bucket to log to itself.
  access_log_bucket = ""

  # Lets delivery.logs.amazonaws.com write VPC flow logs (and later ALB access
  # logs) under AWSLogs/<account-id>/. Must be in place BEFORE the flow log is
  # created: CreateFlowLogs validates the destination bucket policy and fails
  # outright if delivery is not permitted.
  allow_aws_log_delivery = true
}
