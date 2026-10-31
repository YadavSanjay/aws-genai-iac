# Baseline tier security groups: public ALB and application.
#
# Only the tiers whose contract is already settled by the approved design. The
# Qdrant, RDS and NAT-instance groups are deliberately absent — their ports and
# access patterns should be decided WITH those services, not guessed here and
# corrected later.
#
# Rules are written as separate aws_vpc_security_group_*_rule resources rather
# than inline blocks. Inline rules are authoritative for the whole group, so a
# rule added later by another module silently deletes the others; the separate
# resources compose, and each appears individually in a plan.

# --- Public ALB --------------------------------------------------------------

resource "aws_security_group" "alb" {
  # TEMPORARY SKIP — remove when the ALB lands in Phase 3.
  #
  # CKV2_AWS_5 fires because nothing is attached to this group yet, and that is
  # a fair observation rather than a false positive: these groups are defined
  # one step ahead of their consumers so Phase 3 can reference them. The check
  # exists to catch orphaned groups left behind after a teardown, which is a
  # real problem — this is the same shape, temporarily.
  #
  # Unlike the other skips in this repo, this one is time-bounded. If it is
  # still here once the ALB exists, the group is genuinely orphaned and should
  # be deleted rather than skipped.
  #checkov:skip=CKV2_AWS_5:Defined ahead of its consumer; the ALB attaches in Phase 3. Remove this skip then.
  name        = "${var.name_prefix}-alb"
  description = "Public ALB: terminates TLS from the internet, forwards to the app tier."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-alb"
    Tier = "edge"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = var.allow_https ? toset(var.alb_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from permitted sources"

  cidr_ipv4   = each.value
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

# With a certificate this port only ever serves a 301 to HTTPS. WITHOUT one it
# is the sole ingress path and traffic is unencrypted — a real relaxation of the
# encrypt-in-transit rule, acceptable only where no real data flows.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = var.allow_http ? toset(var.alb_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  # NOTE: plain ASCII only. AWS restricts rule descriptions to
  # a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* and rejects anything outside that set,
  # including the em dashes used freely in this repo's prose.
  description = var.allow_https ? "HTTP from permitted sources, redirected to HTTPS" : "HTTP from permitted sources (NO TLS: no certificate available)"

  cidr_ipv4   = each.value
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# Egress to the app tier ONLY, by group reference. Not a CIDR: instances come
# and go, and a CIDR rule would either be too broad or need editing every time
# the subnet layout changes.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward to the application tier"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}


# --- Application tier --------------------------------------------------------

resource "aws_security_group" "app" {
  # TEMPORARY SKIP — remove when app instances land in Phase 3. See the note on
  # aws_security_group.alb above.
  #checkov:skip=CKV2_AWS_5:Defined ahead of its consumer; app instances attach in Phase 3. Remove this skip then.
  name        = "${var.name_prefix}-app"
  description = "Application tier: reachable only from the ALB; egresses to AWS and LLM APIs."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-app"
    Tier = "app"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# The only ingress. No CIDR rule, no SSH: administrative access is via SSM
# Session Manager, which needs no inbound rule at all — the agent dials out.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "Application traffic from the ALB only"

  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# Outbound HTTPS. Unavoidably to 0.0.0.0/0: the workloads call api.openai.com
# and api.anthropic.com, which publish no stable address range. Restricted to
# 443 rather than all ports, and the tier sits in a private subnet reachable
# only through the ALB.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS service endpoints and external LLM APIs"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

# DNS to the Amazon-provided resolver, scoped to the VPC rather than the
# internet. Egress rules apply to outbound traffic even for the VPC resolver, so
# omitting these breaks name resolution in a way that looks like a network fault.
resource "aws_vpc_security_group_egress_rule" "app_dns_udp" {
  security_group_id = aws_security_group.app.id
  description       = "DNS (UDP) to the VPC resolver"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "udp"
  from_port   = 53
  to_port     = 53
}

resource "aws_vpc_security_group_egress_rule" "app_dns_tcp" {
  security_group_id = aws_security_group.app.id
  description       = "DNS (TCP) to the VPC resolver, for responses over 512 bytes"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "tcp"
  from_port   = 53
  to_port     = 53
}

# --- East-west: applications calling each other through the internal ALB ------
#
# Without this the app tier can reach the internet on 443 and nothing inside the
# VPC. A BFF calling RagInference, or one subsystem calling another, goes out
# through the internal load balancer — which needs an explicit egress rule,
# because egress is deliberately not wide open.
#
# By group reference, so it stays correct as instances come and go.
resource "aws_vpc_security_group_egress_rule" "app_to_alb" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Call other applications through the internal ALB"

  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.alb_listener_port
  to_port                      = var.alb_listener_port
}

# Direct call to RagInference via service discovery — NOT through the ALB. The
# app tier resolves raginference.<namespace> and connects to the task IP on the
# service port. By group reference, so it survives task-IP churn.
resource "aws_vpc_security_group_egress_rule" "app_to_raginfer" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Call RagInference directly (service discovery)"

  referenced_security_group_id = aws_security_group.raginfer.id
  ip_protocol                  = "tcp"
  from_port                    = var.raginfer_port
  to_port                      = var.raginfer_port
}

# Direct call to the shared Qdrant vector store on its REST + gRPC ports. Not
# through the ALB — Qdrant is a data tier the app dials directly over the VPC. By
# group reference, so it survives the Qdrant host being stopped/replaced on its
# schedule.
resource "aws_vpc_security_group_egress_rule" "app_to_qdrant_rest" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Query the shared Qdrant vector store (REST)"

  referenced_security_group_id = aws_security_group.qdrant.id
  ip_protocol                  = "tcp"
  from_port                    = var.qdrant_rest_port
  to_port                      = var.qdrant_rest_port
}

resource "aws_vpc_security_group_egress_rule" "app_to_qdrant_grpc" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Query the shared Qdrant vector store (gRPC)"

  referenced_security_group_id = aws_security_group.qdrant.id
  ip_protocol                  = "tcp"
  from_port                    = var.qdrant_grpc_port
  to_port                      = var.qdrant_grpc_port
}

# Direct call to the ARag RDS PostgreSQL instance on 5432. A data tier the app
# dials directly over the VPC (fact + MV reads), by group reference so the rule
# survives the scheduled DB being stopped/started. Only ARag holds DB credentials;
# MacroRAG shares this group but has no reason (or means) to connect.
resource "aws_vpc_security_group_egress_rule" "app_to_rds" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Query the ARag RDS PostgreSQL instance"

  referenced_security_group_id = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = var.rds_port
  to_port                      = var.rds_port
}

# --- East-west: one app tier calling another DIRECTLY -------------------------
#
# Faultline's scenariogen calls ARag and MacroRAG over REST, both of which
# publish their API on app_port. Neither the ALB path above nor any other rule
# covers it: `app_from_alb` admits the ALB alone, so two hosts in this group
# cannot reach each other in either direction, and in dev the ALB is torn down
# (ingress_mode = "ssm") so routing east-west through it is not an option.
#
# SELF-REFERENCING: the rule names this very group as the counterparty, which is
# what lets members of the group talk to each other. It survives instances being
# stopped, started and replaced on their schedules, which a CIDR or an instance
# ARN would not.
#
# DELIBERATE RELAXATION, stated per the provisioning principles: because the
# estate shares ONE app-tier group, this admits ANY app host to ANY other on
# app_port, not just Faultline to its two dependencies. MacroRAG gains a
# path to ARag's API that it has no reason to use. Bounding controls: exactly one
# TCP port (not a range, not all protocols); private subnets only; no CIDR; and
# the tier is already a single trust domain in dev, where these services run
# without auth by explicit decision and the network IS the boundary. The
# least-privilege answer is a group per application, which is a prod-hardening
# change — it would reprovision every existing host — and is recorded as such in
# the module README.
resource "aws_vpc_security_group_ingress_rule" "app_from_app" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Application API traffic from another host in the app tier"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# The matching egress. Both directions are required: security groups are
# stateful for a given rule, but the caller needs egress and the callee needs
# ingress, and here they are the same group wearing both hats.
resource "aws_vpc_security_group_egress_rule" "app_to_app" {
  count = var.enable_east_west ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "Call another application in the app tier directly"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# --- RagInference service tier -----------------------------------------------
#
# A Fargate model server the app tier calls DIRECTLY via service discovery
# (raginference.<namespace>:port), not through the ALB. Its own group, not the
# app tier's: a different port (raginfer_port) and a narrower egress profile — it
# makes NO external (non-AWS) calls, unlike the app tier which reaches out to
# OpenAI/Anthropic. Ingress is the app tier and nothing else.

resource "aws_security_group" "raginfer" {
  # TEMPORARY SKIP — remove when the RagInference service lands (R6) and attaches
  # this group. See the note on aws_security_group.alb above; this is the same
  # "defined one step ahead of its consumer" shape and is time-bounded.
  #checkov:skip=CKV2_AWS_5:Defined ahead of its consumer; the RagInference Fargate service attaches it at R6. Remove this skip then.
  name        = "${var.name_prefix}-raginference"
  description = "RagInference service: reachable only from the app tier; egresses to AWS services only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-raginference"
    Tier = "service"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# The only ingress: the application tier, on the service port. SG-to-SG, so it
# stays correct as both the callers' and the Fargate tasks' IPs come and go.
resource "aws_vpc_security_group_ingress_rule" "raginfer_from_app" {
  security_group_id = aws_security_group.raginfer.id
  description       = "RagInference traffic from the application tier only"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.raginfer_port
  to_port                      = var.raginfer_port
}

# Outbound HTTPS to AWS service endpoints only: ECR API, CloudWatch Logs and
# ssmmessages (ECS Exec) via the NAT, and S3 (weight sync) via the free gateway
# endpoint. Unlike the app tier this carries NO traffic to external LLM APIs —
# RagInference is the model server, it does not call one. The 0.0.0.0/0 is the
# dev compromise for reaching public AWS endpoints without paid interface
# endpoints (dropped in dev, see design §2a); prod adds those and tightens this.
resource "aws_vpc_security_group_egress_rule" "raginfer_https" {
  security_group_id = aws_security_group.raginfer.id
  description       = "HTTPS to AWS service endpoints (ECR, Logs, SSM) and S3"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "raginfer_dns_udp" {
  security_group_id = aws_security_group.raginfer.id
  description       = "DNS (UDP) to the VPC resolver"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "udp"
  from_port   = 53
  to_port     = 53
}

resource "aws_vpc_security_group_egress_rule" "raginfer_dns_tcp" {
  security_group_id = aws_security_group.raginfer.id
  description       = "DNS (TCP) to the VPC resolver, for responses over 512 bytes"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "tcp"
  from_port   = 53
  to_port     = 53
}

# --- Qdrant data tier --------------------------------------------------------
#
# The shared vector store (MacroRAG + ARag collections), self-hosted on a
# dedicated EC2 in 30-shared-svc. Its consumers dial it DIRECTLY over the VPC on
# 6333 (REST) / 6334 (gRPC) — not through the ALB — so it gets its own group:
# ingress is the consumer groups and nothing else, egress is AWS services only
# (ECR image pull, Secrets Manager for the API key, CloudWatch Logs, SSM). Like
# RagInference it makes NO external (non-AWS) calls. See
# docs/design/qdrant-cloud-vs-self-hosted.md §6a.

resource "aws_security_group" "qdrant" {
  # TEMPORARY SKIP — remove when the Qdrant host lands (data/qdrant, chunk D) and
  # attaches this group. Same "defined one step ahead of its consumer" shape as
  # the ALB/app/raginfer groups above; time-bounded.
  #checkov:skip=CKV2_AWS_5:Defined ahead of its consumer; the data/qdrant EC2 attaches it in chunk D. Remove this skip then.
  name        = "${var.name_prefix}-qdrant"
  description = "Qdrant vector store: reachable only from its consumers on 6333/6334; egresses to AWS services only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-qdrant"
    Tier = "data"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: the application tier (MacroRAG today; ARag when it lands adds its own
# rule) on the REST and gRPC ports. SG-to-SG, so it stays correct as the app
# instances and the scheduled Qdrant host come and go. The ARag ingest
# job-runner gets its own ingress rule here when that group exists.
resource "aws_vpc_security_group_ingress_rule" "qdrant_from_app_rest" {
  security_group_id = aws_security_group.qdrant.id
  description       = "Qdrant REST from the application tier"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.qdrant_rest_port
  to_port                      = var.qdrant_rest_port
}

resource "aws_vpc_security_group_ingress_rule" "qdrant_from_app_grpc" {
  security_group_id = aws_security_group.qdrant.id
  description       = "Qdrant gRPC from the application tier"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.qdrant_grpc_port
  to_port                      = var.qdrant_grpc_port
}

# Outbound HTTPS to AWS service endpoints only: ECR image pull, Secrets Manager
# (the API key), CloudWatch Logs and ssmmessages (SSM). No external LLM traffic.
# The 0.0.0.0/0 is the same dev compromise as the raginfer tier — public AWS
# endpoints without paid interface endpoints (dropped in dev, design §2a); prod
# adds those and tightens this.
resource "aws_vpc_security_group_egress_rule" "qdrant_https" {
  security_group_id = aws_security_group.qdrant.id
  description       = "HTTPS to AWS service endpoints (ECR, Secrets Manager, Logs, SSM) and S3"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "qdrant_dns_udp" {
  security_group_id = aws_security_group.qdrant.id
  description       = "DNS (UDP) to the VPC resolver"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "udp"
  from_port   = 53
  to_port     = 53
}

resource "aws_vpc_security_group_egress_rule" "qdrant_dns_tcp" {
  security_group_id = aws_security_group.qdrant.id
  description       = "DNS (TCP) to the VPC resolver, for responses over 512 bytes"

  cidr_ipv4   = var.vpc_cidr
  ip_protocol = "tcp"
  from_port   = 53
  to_port     = 53
}

# --- RDS data tier -----------------------------------------------------------
#
# ARag's PostgreSQL instance (xbrl_db), reached DIRECTLY over the VPC on 5432 by
# the app tier (fact + MV reads) and, when it lands, the ARag ingest job-runner
# (fact writes). Its own group: a data tier admitting only its consumer groups
# on 5432. No egress rules — RDS initiates nothing outbound. See
# docs/design/arag-rollout-plan.md (A4).

resource "aws_security_group" "rds" {
  # TEMPORARY SKIP — remove when the data/rds instance lands (42-arag/db) and
  # attaches this group. Same "defined one step ahead of its consumer" shape as
  # the ALB/app/raginfer/qdrant groups above; time-bounded.
  #checkov:skip=CKV2_AWS_5:Defined ahead of its consumer; the data/rds instance attaches it at A4. Remove this skip then.
  name        = "${var.name_prefix}-rds"
  description = "ARag RDS PostgreSQL: reachable only from its consumers on 5432; initiates no egress."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rds"
    Tier = "data"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Ingress: the application tier on 5432 (ARag app today; the ARag ingest
# job-runner adds its own rule here when that group exists). SG-to-SG, so it
# stays correct as the app instances and the scheduled DB come and go.
resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id = aws_security_group.rds.id
  description       = "PostgreSQL from the application tier"

  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.rds_port
  to_port                      = var.rds_port
}
