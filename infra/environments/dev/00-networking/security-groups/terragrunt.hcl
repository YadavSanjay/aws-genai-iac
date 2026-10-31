# dev / 00-networking/security-groups — baseline tier groups.
#
# Step 6. Public ALB and application tier only. Qdrant, RDS and the NAT instance
# get their groups alongside those services, where the real ports are known.
#
# Cost: $0. Security groups and rules are free.
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
    vpc_id     = "vpc-00000000000000000"
    cidr_block = "10.10.0.0/16"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate"]
}

terraform {
  source = "${get_repo_root()}/infra/modules/networking/security-groups"
}

inputs = {
  name_prefix = local.env.name_prefix
  vpc_id      = dependency.vpc.outputs.vpc_id
  vpc_cidr    = dependency.vpc.outputs.cidr_block

  # MacroRAG is the first workload; its container port is confirmed when the
  # ec2-app module lands. Changing this later is a rule replacement, not a
  # rebuild.
  app_port = 8000

  # NO DOMAIN, THEREFORE NO TLS. ACM requires domain validation, so there is no
  # certificate and no HTTPS listener; 443 would advertise a port nothing
  # answers on. Port 80 is the sole path and traffic is UNENCRYPTED.
  #
  # The ALB is INTERNAL, so that traffic never leaves the VPC — which is what
  # makes the missing certificate tolerable rather than urgent. Revisit when a
  # domain exists. See docs/design/aws-service-consolidation.md §2b.
  allow_https = false
  allow_http  = true

  # The whole VPC, because the ALB is internal and resolves to private
  # addresses. Any in-VPC client reaches it directly — including a Session
  # Manager tunnel opened through ANY instance, which is how a laptop gets
  # there. No public range, and nothing to update when a home IP changes.
  alb_ingress_cidrs = [local.env.vpc_cidr]

  # Applications call each other through the internal ALB, so the app tier needs
  # egress to it. Egress here is deliberately not wide open, and a missing rule
  # would present as an unexplained timeout.
  enable_east_west  = true
  alb_listener_port = 80

  # NOTE: left at the internet default because the ALB is public by design.
  # Worth narrowing to office/VPN ranges — the highest value-per-effort
  # hardening available here, and free.
  # alb_ingress_cidrs = ["<office-cidr>"]
}
