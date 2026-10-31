# `networking/security-groups` — baseline tier groups

Internal ALB and application tier, wired to each other by **group reference** rather
than CIDR.

## Scope: only the tiers whose contract is settled

The ALB, application tier, and the **RagInference** service tier — each added
when its contract was known. Qdrant, RDS and the NAT instance are deliberately
**not** here yet. Their ports and access patterns should be decided alongside
those services — guessing now means editing later, and a security group that
looks reviewed but was invented speculatively is worse than one that does not
exist yet.

When they arrive, they grant ingress by referencing `app_security_group_id` (or
`raginfer_security_group_id`).

## Resources

| Resource | Purpose |
|---|---|
| `aws_security_group.alb` | Shared internal ALB |
| `aws_security_group.app` | Application tier (compose EC2 hosts) |
| `aws_security_group.raginfer` | RagInference Fargate service |
| `*_ingress_rule` / `*_egress_rule` | Individual rules, see below |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `vpc_id` | string | — | |
| `vpc_cidr` | string | — | Scopes intra-VPC egress (DNS) |
| `app_port` | number | `8000` | Single port the ALB forwards to the app tier |
| `raginfer_port` | number | `8799` | Single port the ALB forwards to RagInference |
| `alb_ingress_cidrs` | list(string) | — | Sources permitted to reach the ALB (no default) |
| `tags` | map(string) | `{}` | |

## Outputs

`alb_security_group_id`, `app_security_group_id`, `app_port`,
`raginfer_security_group_id`, `raginfer_port`.

## Security posture

### Rules are separate resources, not inline blocks

Inline `ingress`/`egress` blocks are **authoritative for the entire group**: a
rule added later by another module silently deletes every rule it does not know
about. The separate `aws_vpc_security_group_*_rule` resources compose, and each
one shows up individually in a plan — so adding a rule reads as one addition
rather than a wholesale replacement.

### Group references, not CIDRs

The ALB reaches the app tier by referencing its group id, and vice versa. A CIDR
rule would have to be either broader than the tier (the whole subnet) or
rewritten whenever the subnet layout changed. Group references stay correct as
instances come and go.

### No SSH, anywhere

There is no port 22 rule and no bastion. Administrative access is via **SSM
Session Manager**, whose agent dials outbound — it needs no inbound rule at all.
An SSH rule would be the single most likely thing to be left open by accident.

### The one unavoidable wide rule

`app_https` egresses to `0.0.0.0/0` on port 443. The workloads call
`api.openai.com` and `api.anthropic.com`, which publish no stable address range,
so this cannot be narrowed by CIDR.

Compensating controls: restricted to port 443 rather than all ports, the tier
sits in a private subnet reachable only through the ALB, and S3 traffic bypasses
it entirely via the gateway endpoint. `CKV_AWS_382` is skipped on this rule with
that reasoning.

### The self-referencing app→app rule is a deliberate relaxation

`app_from_app` / `app_to_app` let members of the app tier reach each other on
`app_port`. Faultline needs it: its `scenariogen` calls XbrlRag and MacroRAG
over REST, both of which serve on that port, and no other rule covers the path —
`app_from_alb` admits the ALB alone, and in dev the ALB is torn down
(`ingress_mode = "ssm"`), so routing east-west through it is not available.

**What it widens.** Because the estate shares *one* app-tier group, this admits
any app host to any other on `app_port`, not only Faultline to its two
dependencies. MacroRAG gains a path to XbrlRag's API it has no reason to use.

**Bounding controls:** exactly one TCP port — not a range, not all protocols;
private subnets only; a group reference rather than a CIDR; and the tier is
already a single trust domain in dev, where these services run without
application auth by explicit decision, so the network *is* the boundary.

**The prod answer is a group per application**, which is not a drop-in change:
every existing host would be reprovisioned onto its new group. Treat this rule
as dev-scoped and revisit it with the rest of the prod-hardening set (ALB + ACM,
OIDC at the edge, per-AZ NAT).

### The RagInference tier is narrower than the app tier

RagInference has its own group (`raginfer`), not the app tier's, because its
contract differs: a different port (`raginfer_port`, 8799) and a **smaller egress
surface**. It admits only the **app tier** on 8799 — callers reach it **directly
via Cloud Map service discovery** (`raginference.<namespace>:8799`; see
[`networking/dns`](../dns/README.md)), not through the ALB — and egresses 443 to
reach **AWS service endpoints only**: ECR API,
CloudWatch Logs and `ssmmessages` (ECS Exec) via the NAT, and S3 (weight sync)
via the gateway endpoint. Unlike the app tier it carries **no external-LLM
traffic**: RagInference is the model server, it does not call one. The
`0.0.0.0/0` on 443 is the dev compromise for reaching public AWS endpoints
without paid interface endpoints (dropped in dev, design §2a); prod adds those
and tightens it. The app tier gets a matching egress rule (`app_to_raginfer`,
gated on `enable_east_west`) so it can make the call.

### `allow_http_redirect` defaults to false

Strictest, and keeps checkov clean. Enabling it trades a finding for usability:
without it, a user typing `http://` gets a connection failure rather than a
redirect. Nothing sensitive crosses port 80 either way, since the listener only
issues a 301.

### `alb_ingress_cidrs` is worth narrowing

There is no default — the value is set explicitly per environment (dev currently
passes the whole VPC CIDR, since the ALB is **internal**). If a domain later makes
the ALB internet-facing, narrowing this to office or VPN ranges is a cheap,
high-value-per-effort control; even while internal, tightening it below the whole
VPC limits lateral reach.

## Cost profile

**$0.00/month.** Security groups and their rules are free, and there is no
per-rule or per-evaluation charge.

The cost relevance is indirect: these groups are what keep the ALB the single
shared entry point, so nothing else needs a public IP ($3.60/month each) or its
own load balancer (~$16.43/month each).
