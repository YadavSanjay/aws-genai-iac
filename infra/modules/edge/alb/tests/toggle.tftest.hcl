# Plan-time tests for the edge/alb ingress switch. Runs with NO AWS credentials
# via a mocked provider.
#
#   terraform -chdir=infra/modules/edge/alb test
#
# The property the whole design rests on: enabled = true creates the load
# balancer, its target group and listener; enabled = false (ingress_mode = "ssm")
# creates NOTHING billable. A surviving ALB after the flip is a pure cost leak.
# Post-apply behaviour is verified against the live API in tests/integration.

mock_provider "aws" {}

variables {
  name_prefix        = "genai-dev"
  vpc_id             = "vpc-00000000000000000"
  private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  security_group_id  = "sg-00000000000000000"

  targets = {
    macrorag = {
      instance_id       = "i-00000000000000000"
      port              = 8000
      health_check_path = "/"
      path_patterns     = [] # default action
    }
  }
}

run "enabled_creates_the_load_balancer" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = length(aws_lb.this) == 1
    error_message = "enabled = true must create the load balancer"
  }
  assert {
    condition     = one(aws_lb.this).internal == true
    error_message = "this ALB is internal (east-west) by default"
  }
  assert {
    condition     = length(aws_lb_target_group.this) == 1 && contains(keys(aws_lb_target_group.this), "macrorag")
    error_message = "each target gets a target group"
  }
  assert {
    condition     = length(aws_lb_listener.this) == 1
    error_message = "an enabled ALB must have a listener"
  }
}

run "ssm_mode_creates_nothing" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(aws_lb.this) == 0
    error_message = "ingress_mode=ssm (enabled=false) must create NO load balancer"
  }
  assert {
    condition     = length(aws_lb_target_group.this) == 0 && length(aws_lb_listener.this) == 0
    error_message = "no target groups or listeners exist when the ALB is off"
  }
}
