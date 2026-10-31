# dev / 00-networking/endpoints — S3 gateway endpoint.
#
# Step 5. Free, and it keeps S3 traffic (including ECR image layers) off the
# future NAT instance, where it would otherwise be billed at $0.045/GB.
#
# Cost: $0.00. Gateway endpoints have no hourly or data-processing charge.
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

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "subnets" {
  config_path = "../subnets"

  mock_outputs = {
    all_route_table_ids = ["rtb-00000000000000000"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/endpoints"
}

inputs = {
  name_prefix = local.env.name_prefix
  vpc_id      = dependency.vpc.outputs.vpc_id
  region      = local.merged.region

  # ALL route tables, public and private. A table left out keeps routing S3 the
  # long way with no error anywhere — silently paying NAT charges.
  route_table_ids = dependency.subnets.outputs.all_route_table_ids

  # Writable: the project's own buckets. Everything else is read-only through
  # the endpoint, which keeps ECR pulls and OS package installs working while
  # closing the write-out exfiltration path.
  writable_bucket_arns = [
    "arn:aws:s3:::genai-*",
    "arn:aws:s3:::${local.merged.state_bucket}",
  ]
}
