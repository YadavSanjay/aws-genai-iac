# dev / 00-networking/subnets — subnets and route tables.
#
# Step 4. Public and private tiers across 2 AZs, public route table to the IGW,
# one private route table per AZ. No NAT route — private subnets have local
# routes only until an egress device exists (design doc §2a).
#
# Cost: $0. Subnets, route tables and associations are all free.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs = {
    vpc_id              = "vpc-00000000000000000"
    cidr_block          = "10.10.0.0/16"
    internet_gateway_id = "igw-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/subnets"
}

inputs = {
  name_prefix         = local.env.name_prefix
  vpc_id              = dependency.vpc.outputs.vpc_id
  vpc_cidr            = dependency.vpc.outputs.cidr_block
  internet_gateway_id = dependency.vpc.outputs.internet_gateway_id

  # Two AZs: the minimum for any HA story, and free — subnets and route tables
  # cost nothing, so there is no reason to start with one. Per-AZ charges only
  # appear with NAT devices, load balancer nodes and cross-AZ data transfer.
  az_count = 2
}
