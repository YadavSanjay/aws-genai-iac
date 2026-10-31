# Plan-time tests for the Qdrant data-tier security group. Mocked provider, no
# AWS credentials.
#
#   terraform -chdir=infra/modules/networking/security-groups test
#
# The security property: Qdrant admits ONLY its consumer groups (the app tier
# today), on 6333/6334 by SG reference, and egresses to AWS services (443) + DNS
# — never arbitrary ingress, never a CIDR-based admit. Consumers reach it
# directly over the VPC, not via the ALB. Post-apply, tests/integration verifies
# the same against the live rules.

mock_provider "aws" {}

variables {
  name_prefix       = "genai-dev"
  vpc_id            = "vpc-00000000000000000"
  vpc_cidr          = "10.10.0.0/16"
  alb_ingress_cidrs = ["10.10.0.0/16"]
}

run "qdrant_admits_only_consumer_groups_on_its_ports" {
  # apply against the mocked provider: SG-to-SG references are computed ids,
  # unknown at plan, so they resolve only once the mock applies.
  command = apply

  # Ingress is by group reference to the app tier, on the two Qdrant ports —
  # never a CIDR, and never the ALB.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.qdrant_from_app_rest.referenced_security_group_id == aws_security_group.app.id
    error_message = "Qdrant REST ingress must reference the app tier group, not a CIDR or the ALB"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.qdrant_from_app_rest.from_port == 6333 && aws_vpc_security_group_ingress_rule.qdrant_from_app_rest.to_port == 6333
    error_message = "Qdrant REST ingress must be the single port 6333"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.qdrant_from_app_grpc.referenced_security_group_id == aws_security_group.app.id
    error_message = "Qdrant gRPC ingress must reference the app tier group, not a CIDR or the ALB"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.qdrant_from_app_grpc.from_port == 6334 && aws_vpc_security_group_ingress_rule.qdrant_from_app_grpc.to_port == 6334
    error_message = "Qdrant gRPC ingress must be the single port 6334"
  }

  # Egress: HTTPS to AWS services must be 443 only, not an all-ports opening.
  assert {
    condition     = aws_vpc_security_group_egress_rule.qdrant_https.from_port == 443 && aws_vpc_security_group_egress_rule.qdrant_https.to_port == 443
    error_message = "Qdrant egress must be scoped to 443, not all ports"
  }

  # The app tier must be able to reach Qdrant directly on both ports.
  assert {
    condition     = one(aws_vpc_security_group_egress_rule.app_to_qdrant_rest).referenced_security_group_id == aws_security_group.qdrant.id && one(aws_vpc_security_group_egress_rule.app_to_qdrant_rest).to_port == 6333
    error_message = "the app tier must have an egress rule to Qdrant on 6333"
  }
  assert {
    condition     = one(aws_vpc_security_group_egress_rule.app_to_qdrant_grpc).referenced_security_group_id == aws_security_group.qdrant.id && one(aws_vpc_security_group_egress_rule.app_to_qdrant_grpc).to_port == 6334
    error_message = "the app tier must have an egress rule to Qdrant on 6334"
  }
}
