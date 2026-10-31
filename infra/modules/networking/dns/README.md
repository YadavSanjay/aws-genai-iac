# `networking/dns` — private service-discovery namespace

A **Cloud Map private DNS namespace** (which creates a VPC-scoped Route53 private
hosted zone) for east-west service discovery. Backend Fargate services register a
Cloud Map service under it and become reachable at `<service>.<namespace>:<port>`
from any in-VPC client — no load balancer, no public exposure.

`raginference.genai-dev.internal:8799` is the first consumer; Qdrant will be the
next (`qdrant.genai-dev.internal`).

## Why this, not the internal ALB

For a **pure backend service** (called by sibling services in code, never by a
browser) service discovery is the right primitive:

- **Matches the client contract.** RagInference's plan specifies
  `RAGINFER_URL=http://raginfer.internal:8799` — a DNS name, which is exactly
  what this produces, not an ALB path (`<alb>/raginfer/*`).
- **No listener, no hourly charge.** A namespace is free; an ALB is $16.43/mo and
  needs a target group associated before an ECS service can even be created.
- **Unaffected by the ingress toggle.** `ingress_mode` governs *user-facing*
  reach; east-west calls between services should not disappear when it flips to
  `ssm`. Discovery keeps RagInference reachable in-VPC in either mode.

The internal ALB remains for anything that genuinely needs path-based HTTP
routing or a single front door; backend APIs use this.

The tier's network access (ingress from the app tier on 8799, AWS-endpoint-only
egress) is defined in [`networking/security-groups`](../security-groups/README.md).

## Resources

| Resource | Purpose |
|---|---|
| `aws_service_discovery_private_dns_namespace.this` | Cloud Map namespace + Route53 private zone |

The per-service Cloud Map **service** (the `<service>` record) is created by the
consuming service module (`compute/ecs-service`), not here — it lives with the
service it registers.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `namespace_name` | string | — | e.g. `genai-dev.internal` (VPC-private) |
| `vpc_id` | string | — | The only VPC the namespace resolves in |
| `tags` | map(string) | `{}` | |

## Outputs

`namespace_id` (pass to a service module), `namespace_arn`, `namespace_name`,
`hosted_zone_id`.

## Cost profile

**~$0.50/month** — a Route53 private hosted zone is $0.50/mo; Cloud Map DNS
queries are billed per million (negligible at dev volume). No hourly compute.
