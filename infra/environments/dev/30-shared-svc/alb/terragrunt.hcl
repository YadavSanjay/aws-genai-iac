# dev / 30-shared-svc/alb — shared Application Load Balancer.
#
# Phase 3b. Switchable: driven entirely by `ingress_mode` in dev/env.hcl.
#   "alb" -> load balancer exists, ~$16.43/mo, UNPAUSABLE
#   "ssm" -> nothing is created; reach applications via Session Manager tunnels
#
# Shared across all subsystems, so it depends on the application components
# rather than the other way round — which is why it sits in 30-shared-svc and
# not 00-networking despite being networking-shaped.
#
# NO TLS: there is no registered domain, so ACM cannot issue a certificate and
# the listener is plain HTTP. See docs/design/aws-service-consolidation.md §2b.
#
# Apply as the exec role: AWS_PROFILE=genai-tf
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../../00-networking/vpc"

  mock_outputs = {
    vpc_id = "vpc-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "subnets" {
  config_path = "../../00-networking/subnets"

  mock_outputs = {
    private_subnet_ids = ["subnet-00000000000000000", "subnet-00000000000000001"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "security_groups" {
  config_path = "../../00-networking/security-groups"

  mock_outputs = {
    alb_security_group_id = "sg-00000000000000000"
    app_port              = 8000
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

dependency "macrorag" {
  config_path = "../../41-macrorag/app"

  mock_outputs = {
    instance_id = "i-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/edge/alb"
}

inputs = {
  # THE SWITCH. Flip ingress_mode in dev/env.hcl and apply.
  enabled = local.env.ingress_mode == "alb"

  name_prefix = local.env.name_prefix
  vpc_id      = dependency.vpc.outputs.vpc_id

  # INTERNAL: the load balancer resolves to PRIVATE addresses and lives in the
  # private subnets. Its purpose is east-west traffic — subsystems calling each
  # other and RagInference — which is all inside the VPC.
  #
  # An internet-facing ALB could not serve that: an in-VPC client would egress
  # through the NAT and arrive with the NAT's public source address, which is
  # auto-assigned and changes on every restart. There is no CIDR to allowlist.
  #
  # A laptop reaches it by tunnelling through any instance:
  #   aws ssm start-session --target <instance-id> \
  #     --document-name AWS-StartPortForwardingSessionToRemoteHost \
  #     --parameters '{"host":["<alb-dns>"],"portNumber":["80"],"localPortNumber":["8080"]}'
  internal           = true
  private_subnet_ids = dependency.subnets.outputs.private_subnet_ids
  security_group_id  = dependency.security_groups.outputs.alb_security_group_id

  targets = {
    macrorag = {
      instance_id = dependency.macrorag.outputs.instance_id
      port        = dependency.security_groups.outputs.app_port

      # "/" until the application exposes a real health endpoint. A health check
      # against a path the app does not serve marks the target unhealthy and the
      # ALB returns 503 — which looks like the app is down when it is the probe
      # that is wrong.
      health_check_path = "/"

      # Empty: MacroRAG is the DEFAULT action while it is the only target here.
      # RagInference is NOT on the ALB — as a backend API it uses Cloud Map
      # service discovery (raginference.<namespace>:8799), not path routing.
      path_patterns = []
    }
  }

  # No certificate — no registered domain, so ACM cannot validate one. The
  # listener is plain HTTP and traffic is UNENCRYPTED.
  certificate_arn = ""

  # Must stay false: deletion protection would prevent ingress_mode = "ssm"
  # from destroying this. prod should enable it.
  deletion_protection = false
}
