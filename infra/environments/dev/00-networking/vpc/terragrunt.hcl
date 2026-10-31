# dev / 00-networking/vpc — VPC skeleton.
#
# Step 3. VPC + Internet Gateway + stripped default security group + flow logs.
# No subnets, route tables or NAT — each is its own step.
#
# Moved into a `vpc/` subfolder (it was previously 00-networking/terragrunt.hcl)
# so this tier matches 10-security and 20-data, and so subnets/nat/endpoints can
# sit alongside as siblings. Safe to move: the old path was never applied, so no
# state exists under the old key.
#
# Cost: $0 for the VPC, IGW and default SG. Flow logs ~$0.25/GB ingested, which
# is pennies with no workloads running.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "logs_bucket" {
  config_path = "../../20-data/logs-bucket"

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::mock-logs-bucket"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/vpc"
}

inputs = {
  name_prefix = local.env.name_prefix
  cidr_block  = local.env.vpc_cidr

  # The bucket already grants delivery.logs.amazonaws.com write access under
  # AWSLogs/<account>/, and the CMK grants that principal GenerateDataKey.
  # Both are prerequisites — CreateFlowLogs validates the bucket policy up
  # front, and a missing KMS grant would leave the flow log ACTIVE but silent.
  flow_log_destination_arn = dependency.logs_bucket.outputs.bucket_arn

  # dev: full traffic capture is affordable and more useful while building out.
  # Revisit REJECT-only for prod, where volume makes ALL expensive.
  flow_log_traffic_type = "ALL"
}
