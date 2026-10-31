# `edge/alb` — shared Application Load Balancer, switchable

Shared ALB with target groups, a listener and path-based routing rules, gated on
an ingress switch. Used for EC2-instance app tiers that need a shared HTTP front
door; backend APIs use Cloud Map service discovery (`networking/dns`) instead.

## The switch is the point

**When `enabled = false` this module creates nothing.** Not a stripped-down
load balancer — nothing at all.

That is deliberate. An ALB **cannot be stopped** the way an EC2 instance can; it
bills **$16.43/month** for every month it exists regardless of traffic. So "off"
has to mean "destroyed", and applications fall back to SSM port forwarding,
which needs no infrastructure and exposes nothing:

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8000"],"localPortNumber":["8000"]}'
```

Driven by `ingress_mode` in the environment's `env.hcl` — `"alb"` or `"ssm"` —
so the switch is a version-controlled change, not a console action, and an
environment's ingress state is always visible in git.

**Security groups are not toggled.** They cost nothing and the app tier's
ingress rule references the ALB group by id, so destroying it would break that
reference. Only billable resources are gated. The consequence is that flipping
back on recreates just the load balancer.

### Switching

```hcl
# infra/environments/dev/env.hcl
ingress_mode = "ssm"   # or "alb"
```

```bash
cd infra/environments/dev/30-shared-svc/alb
AWS_PROFILE=genai-tf terragrunt apply
```

Going to `ssm` shows a plan that **destroys** the load balancer, listener and
target groups. That is expected and safe — read it to confirm nothing else is
in the plan.

### The round trip is tested, with two caveats

Validated end to end on 2026-07-21: `alb` → `ssm` (destroy, ~54s) → `ssm` →
`alb` (recreate, ~3m). It came back clean, the target re-registered
automatically, and there were no stale references — the `env.hcl` switch drives
everything, so nothing holds a hardcoded ARN or id across the cycle.

Two things that survive the round trip in a way callers must know:

- **A flip back to `alb` re-registers targets, which requires the instances
  RUNNING.** If an app instance is stopped, the recreate apply fails at
  `RegisterTargets`. Start the instances before flipping on.
- **The ALB DNS name changes on every recreate.** A new load balancer gets a
  new `internal-...elb.amazonaws.com` hostname, so any saved SSM tunnel command
  or bookmark goes stale. Read the current name from the `dns_name` output, do
  not cache it.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `enabled` | bool | `false` | The switch |
| `name_prefix` | string | — | e.g. `genai-dev` |
| `vpc_id` | string | — | |
| `private_subnet_ids` | list(string) | — | **At least two AZs** — AWS rejects a single-AZ ALB |
| `security_group_id` | string | — | From `networking/security-groups` |
| `targets` | map(object) | `{}` | EC2 instance targets — see below |
| `certificate_arn` | string | `""` | Empty ⇒ plain HTTP |
| `internal` | bool | `false` | |
| `idle_timeout_seconds` | number | `120` | See note |
| `access_logs_bucket` | string | `""` | |
| `deletion_protection` | bool | `false` | Must stay false here |
| `tags` | map(string) | `{}` | |

### `targets`

```hcl
targets = {
  macrorag = {
    instance_id       = "i-..."
    port              = 8000
    health_check_path = "/health"
    path_patterns     = []      # empty ⇒ this is the DEFAULT action
    priority          = 100
  }
}
```

Exactly one target may have empty `path_patterns` — the ALB needs a default
action, and only one target can hold it. Validated.

With no default target the listener returns a **404 fixed response** rather than
forwarding to whichever target sorted first. "No application claims this path"
is more honest than a silent misroute.

> **Backend services do not belong here.** A pure backend API called by other
> services in code (e.g. RagInference) uses **Cloud Map service discovery**
> (`networking/dns`), not this ALB — it needs no path routing, and an
> ALB-fronted ECS service hits a chicken-and-egg (the target group must be
> load-balancer-associated *before* the service can be created). This module is
> for EC2-instance targets and anything genuinely needing a shared HTTP front
> door.

## No domain, therefore no TLS

ACM issues certificates only after **domain validation**, and no domain is
registered. So:

- the listener is **HTTP on port 80**, and traffic is **unencrypted**
- routing is **path-based** (`/macrorag/*`), not host-based
- the address is the AWS-generated `...elb.amazonaws.com` hostname

**This is a deliberate relaxation of the encrypt-in-transit rule**, acceptable
only because dev carries no real data. Two ways to close it, and one should
happen before anything real flows: register a domain and issue an ACM
certificate (the module takes `certificate_arn` and switches to HTTPS/TLS 1.3
automatically), or narrow `alb_ingress_cidrs` on the security group to known
addresses.

Host-based routing (`macrorag.<domain>`) arrives with the domain.

## Other decisions worth knowing

- **`idle_timeout_seconds = 120`**, not the 60-second default. A single
  LLM-backed request can legitimately run longer than 60s, and the ALB returns
  **504 while the application is still working** — which reads like an
  application bug rather than a load balancer timeout.
- **`drop_invalid_header_fields = true`** — drops malformed requests instead of
  forwarding them, cheap protection against request-smuggling shapes that rely
  on the ALB and the application disagreeing about where a request ends.
- **`unhealthy_threshold = 3`** — two is twitchy on a host whose container may
  be restarting; five delays noticing a genuinely dead application.
- **`deregistration_delay = 30`**, not 300. These are scheduled hosts; waiting
  five minutes to drain a dev instance is pure delay.
- **`deletion_protection = false`** and must stay so — protection would defeat
  the ingress switch. Enable it in prod.

## Targets must be RUNNING to register — once only

`RegisterTargets` fails on a stopped instance:

```
InvalidTarget: The following targets are not in a running state and
cannot be registered: 'i-...'
```

**Registration is one-time.** Once registered, a target stays registered across
stop/start forever — it simply reports unhealthy while stopped. Only the
*initial* registration needs the instance up.

So when adding a new subsystem to this ALB, start its instance before applying.
This recurs once per subsystem: MacroRAG, XbrlRag, Faultline, RagInference.

## Replacing an instance orphans its schedule

Not this module's behaviour, but discovered alongside it and worth knowing.

Terragrunt dependency outputs do **not** propagate to dependents automatically.
When the NAT instance was replaced, its `instance_id` changed — and the
`nat-schedule` component kept targeting the destroyed instance until it was
re-applied. The schedule would have fired that night and silently failed.

After replacing any instance, re-apply everything that references it, or use
`terragrunt run --all apply` so the graph is walked. There is a test asserting
schedules point at live instances precisely because this failure is invisible.

## Cost profile

| Line item | Rate | Notes |
|---|---|---|
| ALB hours | $0.0225/hr → **$16.43/mo** | **Unpausable while it exists** |
| LCU | $0.008/LCU-hr | Negligible at dev traffic |
| Target groups, listeners, rules | free | |

**Amortisation is the argument for enabling it.** One ALB serving four
subsystems is ~$4.11 per application; one ALB serving a single scheduled app
that runs 10 hours a day is $16.43 for something idle 58% of the time.

That is exactly why the switch exists: turn it on for the narrow window where
the subsystems must interoperate, and off again afterwards.

## Verification

`tests/integration/test_alb.py` adapts to the mode. When enabled it asserts
scheme, subnets across two AZs, security group, idle timeout, invalid-header
dropping, target group health-check settings, registration, and listener
configuration. When disabled it asserts **no load balancer exists** — because
"disabled" must mean "not billing", and a surviving ALB is exactly the failure
that would go unnoticed.
