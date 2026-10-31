# Shared Application Load Balancer — entirely gated on var.enabled.
#
# When enabled = false this module creates NOTHING. That is the design, not a
# limitation: an ALB cannot be stopped the way an EC2 instance can, so the only
# way to stop paying $16.43/month is for it not to exist. Applications remain
# reachable via SSM port forwarding, which needs no infrastructure at all.
#
# See docs/design/aws-service-consolidation.md §2b.

locals {
  enabled = var.enabled

  # Only create resources when enabled. Using a set keyed on the map keys keeps
  # target group addresses stable across toggles.
  targets = local.enabled ? var.targets : {}

  # Exactly one target carries the default action; the rest get listener rules.
  default_target = [for name, t in var.targets : name if length(t.path_patterns) == 0]
  routed_targets = { for name, t in local.targets : name => t if length(t.path_patterns) > 0 }

  # No certificate means no HTTPS listener. Plain HTTP is then the sole path in.
  use_https     = var.certificate_arn != ""
  listener_port = local.use_https ? 443 : 80
}

resource "aws_lb" "this" {
  # ACCEPTED for dev, and a REAL finding for prod — do not inherit this skip.
  #
  # CKV2_AWS_28 wants a WAF web ACL in front of a public ALB. A web ACL is
  # $5/month plus $1 per rule plus $0.60 per million requests, so a useful
  # rule set lands around $6-10/month on top of a $16.43 load balancer — 40-60%
  # again, to filter traffic for an environment that carries no real data and
  # is reachable only in narrow windows.
  #
  # It also would not address the actual exposure here, which is that there is
  # no TLS (no domain, so ACM cannot issue a certificate). WAF inspects
  # requests; it does not encrypt them.
  #
  # The cheap, effective mitigation is narrowing alb_ingress_cidrs on the
  # security group to known addresses — free, and it removes the internet from
  # the threat model entirely rather than filtering it.
  #
  # prod, serving real traffic over TLS, should have a WAF.
  #checkov:skip=CKV2_AWS_28:WAF is ~$6-10/mo on a $16.43 dev ALB carrying no real data, and does not address the actual gap (no TLS). Narrow alb_ingress_cidrs instead. prod must have one.
  count = local.enabled ? 1 : 0

  name               = "${var.name_prefix}-alb"
  internal           = var.internal
  load_balancer_type = "application"
  subnets            = var.private_subnet_ids
  security_groups    = [var.security_group_id]

  idle_timeout = var.idle_timeout_seconds

  # False by design. Deletion protection would defeat the ingress switch —
  # flipping to "ssm" must be able to destroy this. prod should enable it.
  enable_deletion_protection = var.deletion_protection

  # Drop malformed requests rather than forwarding them. Cheap protection
  # against request-smuggling shapes that rely on the ALB and the application
  # disagreeing about where a request ends.
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.access_logs_bucket != "" ? [1] : []

    content {
      bucket  = var.access_logs_bucket
      prefix  = "${var.name_prefix}-alb"
      enabled = true
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb"
    Tier = "edge"
  })
}

# --- Target groups -----------------------------------------------------------

resource "aws_lb_target_group" "this" {
  for_each = local.targets

  name        = substr("${var.name_prefix}-${each.key}", 0, 32)
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled           = true
    path              = each.value.health_check_path
    protocol          = "HTTP"
    matcher           = "200-399"
    interval          = 30
    timeout           = 5
    healthy_threshold = 2
    # Three failures before draining. Two is twitchy on a host whose container
    # may be restarting; five delays noticing a genuinely dead application.
    unhealthy_threshold = 3
  }

  # Applications here are stateless HTTP; anything needing affinity should say
  # so explicitly rather than inheriting it.
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  # Give in-flight requests time to finish when a target is deregistered.
  # Shorter than the default 300s because these are scheduled hosts — waiting
  # five minutes to drain a dev instance is pure delay.
  deregistration_delay = 30

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.key}"
    App  = each.key
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each = local.targets

  target_group_arn = aws_lb_target_group.this[each.key].arn
  target_id        = each.value.instance_id
  port             = each.value.port
}

# --- Listener ----------------------------------------------------------------

resource "aws_lb_listener" "this" {
  count = local.enabled ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = local.listener_port
  protocol          = local.use_https ? "HTTPS" : "HTTP"

  # TLS 1.2 minimum when a certificate exists. Null otherwise — an HTTP listener
  # rejects both arguments.
  ssl_policy      = local.use_https ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null
  certificate_arn = local.use_https ? var.certificate_arn : null

  # The default action serves anything matching no listener rule.
  dynamic "default_action" {
    for_each = length(local.default_target) > 0 ? [local.default_target[0]] : []

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this[default_action.value].arn
    }
  }

  # With no default target, refuse rather than guess. A 404 here means "no
  # application claims this path", which is more honest than forwarding to
  # whichever target happened to sort first.
  dynamic "default_action" {
    for_each = length(local.default_target) == 0 ? [1] : []

    content {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "No application is registered as the default route."
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener_rule" "this" {
  for_each = local.enabled ? local.routed_targets : {}

  listener_arn = aws_lb_listener.this[0].arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  # Path-based, not host-based. Host-based routing (macrorag.<domain>) needs a
  # registered domain, which does not exist yet — see design §2b.
  condition {
    path_pattern {
      values = each.value.path_patterns
    }
  }
}
