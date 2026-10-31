# dev / 00-networking/nat — NAT instance.
#
# Phase 3, first piece. A t4g.nano rather than a NAT Gateway: the Gateway bills
# 24/7 with no stop state and would be the largest line item in dev once app
# instances are scheduled off-hours. See design doc §2a.
#
# Cost: ~$7.31/mo running, ~$0.64/mo stopped. Scheduling lands as a separate
# change once this is proven to work.
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

  # Same AZ for the instance and the route tables that use it. Cross-AZ traffic
  # to a NAT device costs $0.01/GB in EACH direction, which can exceed the
  # instance's own cost. Single NAT in dev is the §2a decision, so the other
  # AZ's private subnet does route across — accepted knowingly at dev volume.
  nat_az = "us-east-1a"
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
    public_subnet_ids_by_az       = { "us-east-1a" = "subnet-00000000000000000" }
    private_route_table_ids       = ["rtb-00000000000000000"]
    private_subnet_ids_by_az      = { "us-east-1a" = "subnet-00000000000000001" }
    private_route_table_ids_by_az = { "us-east-1a" = "rtb-00000000000000000" }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "kms" {
  config_path = "../../10-security/kms"

  mock_outputs = {
    key_arn = "arn:aws:kms:us-east-1:000000000000:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/nat-instance"
}

inputs = {
  name_prefix      = local.env.name_prefix
  vpc_id           = dependency.vpc.outputs.vpc_id
  public_subnet_id = dependency.subnets.outputs.public_subnet_ids_by_az[local.nat_az]

  # Both private route tables. The far-AZ one incurs cross-AZ charges; at dev
  # volume that is pennies, and a second NAT instance would cost more than the
  # transfer it saves.
  private_route_table_ids = dependency.subnets.outputs.private_route_table_ids

  # Only the private tier may send traffic through the NAT.
  private_subnet_cidrs = ["10.10.128.0/20", "10.10.144.0/20"]

  # Graviton. Sizing here is bandwidth, not CPU — packet forwarding is nearly
  # free computationally.
  instance_type = "t4g.nano"

  kms_key_arn = dependency.kms.outputs.key_arn

  # The exec role may only create roles carrying the project boundary; without
  # this, CreateRole is refused.
  permissions_boundary_arn = "arn:aws:iam::${local.merged.account_id}:policy/genai-app-boundary"
}
