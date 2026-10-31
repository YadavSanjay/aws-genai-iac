# dev / 00-networking/dns — private service-discovery namespace.
#
# R6. A Cloud Map private DNS namespace (genai-dev.internal) for east-west
# service discovery. RagInference registers under it and resolves at
# raginference.genai-dev.internal:8799 from any in-VPC client — no load balancer,
# no public exposure, unaffected by the ingress toggle. Qdrant will register here
# next.
#
# Cost: ~$0.50/mo (the Route53 private hosted zone); DNS queries are pennies.
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
    vpc_id = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/dns"
}

inputs = {
  name_prefix    = local.env.name_prefix
  namespace_name = "${local.env.name_prefix}.internal"
  vpc_id         = dependency.vpc.outputs.vpc_id
}
