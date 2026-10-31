# Plan-time tests for the RagInference service security group. Mocked provider,
# no AWS credentials.
#
#   terraform -chdir=infra/modules/networking/security-groups test
#
# The security property: RagInference admits ONLY the application tier, on its
# one port, and egresses to AWS services (443) + DNS — never to arbitrary
# ingress. Callers reach it directly via service discovery, not the ALB.
# Post-apply, tests/integration verifies the same against the live rules.

mock_provider "aws" {}

variables {
  name_prefix       = "genai-dev"
  vpc_id            = "vpc-00000000000000000"
  vpc_cidr          = "10.10.0.0/16"
  alb_ingress_cidrs = ["10.10.0.0/16"]
}

run "raginfer_admits_only_the_alb_on_its_port" {
  # apply (against the mocked provider — no real AWS): the SG-to-SG references
  # are computed ids, unknown at plan, so they can only be compared once the
  # mock resolves them.
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.raginfer_from_app.referenced_security_group_id == aws_security_group.app.id
    error_message = "RagInference ingress must reference the app tier group, not a CIDR or the ALB"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.raginfer_from_app.from_port == 8799 && aws_vpc_security_group_ingress_rule.raginfer_from_app.to_port == 8799
    error_message = "RagInference ingress must be the single service port 8799"
  }

  # Egress: HTTPS to AWS services, and DNS — but the HTTPS rule must be 443 only,
  # not an all-ports opening.
  assert {
    condition     = aws_vpc_security_group_egress_rule.raginfer_https.from_port == 443 && aws_vpc_security_group_egress_rule.raginfer_https.to_port == 443
    error_message = "RagInference egress must be scoped to 443, not all ports"
  }

  # The app tier must be able to reach RagInference directly on its port.
  assert {
    condition     = one(aws_vpc_security_group_egress_rule.app_to_raginfer).referenced_security_group_id == aws_security_group.raginfer.id && one(aws_vpc_security_group_egress_rule.app_to_raginfer).to_port == 8799
    error_message = "the app tier must have an egress rule to RagInference on 8799"
  }
}
