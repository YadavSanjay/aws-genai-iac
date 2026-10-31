# Design Decisions & Rationale

Status: living document · Last reconciled with the estate **2026-07-22**.

The **holistic** record of the choices that shape this platform — one place to see
*what* was decided, *why* (cost, architectural simplicity, and fit to the workload
and its data volume), and *where* each decision is applied. It is the overview the
two deep-dive design docs sit under, and the single home for the cross-cutting
rationale that would otherwise be re-argued in every README.

**How to read it.** Each decision is stated once, concisely, with a rationale and a
*status*, then linked to the authoritative detail rather than repeating it:

- **Full analyses** live in [`aws-service-consolidation.md`](aws-service-consolidation.md)
  (service inventory, cost decisions, rollout order) and
  [`qdrant-cloud-vs-self-hosted.md`](qdrant-cloud-vs-self-hosted.md) (the vector-store choice).
- **The "how"** of each resource lives in its module `README.md` under `infra/modules/`.
- **Live component status** is the table on the [status page](../status.md).
- **Provisioning principles** (one-service-at-a-time, real tests, watertight
  security, cost-effective, greenfield baseline) are in [`CLAUDE.md`](../../CLAUDE.md);
  this doc records the *decisions taken under* those principles, not the principles.

---

## 0. Workload context — the fact that drives almost everything

This is an IaC control plane for **four sibling GenAI subsystems** — Faultline,
MacroRAG, XbrlRag, and RagInference — sharing one AWS account. Their shape decides the
architecture more than any single technology preference does:

- **No managed-AI services.** None use Bedrock, SageMaker, EKS, or a managed vector
  DB. "AI" here is external LLM APIs (OpenAI/Anthropic over HTTPS egress) +
  **self-hosted** models (RagInference: BGE-M3 embedder + Jina reranker, CPU-only) +
  **self-hosted Qdrant**. See [`aws-service-consolidation.md` §1](aws-service-consolidation.md#1-headline-finding).
- **The data is tiny.** Faultline ≈ 36 MB total; RagInference weights ≈ 4 GB;
  the shared Qdrant working set is ≈ **200 MB** (~50k × 1024-dim vectors, measured live
  — [`qdrant-cloud-vs-self-hosted.md` §2](qdrant-cloud-vs-self-hosted.md#2-measured-workload-the-fact-that-reshapes-the-decision));
  MacroRAG's relational store is SQLite on EBS.

**Consequence (the thesis of this whole platform): compute + networking are the
entire bill; storage is a rounding error; and nothing is at the scale where
managed-service economics, sharding, or HA begin to pay off.** Almost every decision
below is an application of that single fact — cheapest option that meets the
requirement, and a standing wariness of **always-on line items that cannot be paused**
(NAT Gateway, ALB, managed clusters), because at this size one of those can outweigh
all the application compute it exists to serve.

---

## 1. IaC platform & state

**Decision.** Terraform for resources, **Terragrunt** for DRY multi-component state;
a **single AWS account** with logical `dev`/`staging`/`prod` isolated by name prefix,
tags, and separate VPCs — not separate accounts. Remote state in one S3 bucket, one
key per component, with **S3-native locking** (`use_lockfile`, no DynamoDB table); the
root config is `infra/root.hcl`.

**Rationale.**
- *Simplicity:* one backend, one key-per-component, keeps provider/backend config in
  one place; S3-native locking removes a whole resource (the DynamoDB lock table) that
  the workload never otherwise needs.
- *Cost:* single account and no lock table are both ~$0; the prefix *is* the isolation
  boundary, so no cross-account plumbing.
- *Fit:* a solo/small operator managing four subsystems does not need the blast-radius
  or billing separation of multi-account, and does not want its overhead.
- *Region* `us-east-1` is a **price wash** vs. us-east-2 (verified); the choice is
  operational (blast radius, Spot contention), not cost — see
  [`aws-service-consolidation.md` §6](aws-service-consolidation.md#6-open-items-to-revisit).

**Status.** Applied — state backend + `global/iam-baseline` live. `dev` fully applied.
`staging`/`prod` exist only as empty scaffold directories (no `env.hcl`, not appliable).

**See also.** [`terraform-execution-role.md`](../runbooks/terraform-execution-role.md)
(backend conventions, state-key normalization), [`architecture/README.md`](../architecture/README.md).

---

## 2. Identity & governance

**Decision.** No admin identity ever runs automation. All Terraform assumes a dedicated
**`genai-terraform-exec`** role (reached via a thin `tfuser` whose only power is
`sts:AssumeRole`); every IaC-created role carries the **`genai-app-boundary`**
permissions boundary; there is deliberately **no `[default]` AWS profile**, so an
unpinned call fails rather than silently using admin. Reads by the coding agent go
through a read-only MCP identity (`readonlyagent`) gated on `aws:CalledViaAWSMCP`.

**Rationale.**
- *Security:* power lives on a role with short-lived credentials, contained by a
  boundary that denies the IAM-user/org/account surface and self-modification — so a
  compromised exec run cannot escalate. Least privilege is structural, not advisory:
  policies are ARN-scoped and region-locked, security groups reference other groups
  rather than CIDRs.
- *Simplicity:* a named profile (`genai-tf`) does the assumption; day-to-day commands
  just select it. Guard hooks enforce the identity rules mechanically so they cannot be
  forgotten.
- *Fit:* this is the one place the platform is deliberately *not* minimal — the
  guardrails are sized for an autonomous coding agent operating real infrastructure.

**Status.** Applied.

**See also.** [`terraform-execution-role.md`](../runbooks/terraform-execution-role.md),
[`security/iam-terraform-role/README.md`](../../infra/modules/security/iam-terraform-role/README.md)
(resource/policy table + escalation-containment model), and the AWS-credential rule in
[`CLAUDE.md`](../../CLAUDE.md).

---

## 3. Networking & egress

**Decision.** One shared VPC (`10.10.0.0/16` in dev), two AZs, public + private
subnets, **no public IPs on any workload**, the default security group stripped to
deny-all, flow logs to S3. Egress is a **single scheduled `t4g.nano` NAT *instance***
(not a NAT Gateway) plus a **free S3 gateway endpoint**; interface endpoints are
**dropped in dev**.

**Rationale.**
- *Cost — the headline:* a NAT Gateway bills ~$32.85/mo and **cannot be paused**,
  which directly conflicts with scheduling app compute off overnight — it would become
  the largest single line item in dev. A NAT *instance* has EC2 semantics, genuinely
  stops on schedule, and lands at ~$3/mo (~91% cheaper). Interface endpoints
  (~$7.30/mo each) are not worth it at dev volume — the NAT data-processing they would
  save is pennies (break-even ≈ 162 GB/mo per service). The S3 gateway endpoint is free
  and keeps ECR image-layer pulls off the NAT path.
- *Simplicity:* single NAT (not per-AZ), single-AZ placement of the scheduled workloads
  to avoid cross-AZ traffic; per-AZ private route tables are free future-proofing.
- *Fit:* accepts a single point of failure and self-owned patching in dev; **prod keeps
  the NAT Gateway**, where an unattended 3am failure costs more than the saving.

**Status.** Applied.

**See also.** [`aws-service-consolidation.md` §2a](aws-service-consolidation.md#2a-egress-revision--nat-instance-not-nat-gateway-2026-07-20)
(full cost tables + accepted trade-offs), and the `networking/nat-instance`,
`networking/endpoints`, `networking/subnets`, and `networking/vpc` module READMEs.

---

## 4. Ingress & service discovery

**Decision.** User-facing ingress is a **switchable** shared internal ALB or **SSM port
forwarding**, chosen per environment via `ingress_mode` in `env.hcl`; setting `ssm`
destroys the ALB. East-west (service-to-service) traffic uses **Cloud Map private DNS**
(`*.genai-dev.internal`), *not* the ALB. With no registered domain, the ALB serves
**plain HTTP** (no TLS), path-based routing.

**Rationale.**
- *Cost:* like the NAT Gateway, an ALB **cannot be stopped** — ~$16.43/mo for as long
  as it exists. For an app scheduled to run ~10h/day it would be most of dev's spend
  serving something idle most of the time, so the billable resources are gated behind a
  version-controlled switch; SSM forwarding needs no new infrastructure, exposes
  nothing publicly, and requires AWS credentials (exactly the right audience during
  build-out). A Cloud Map namespace is ~$0.50/mo with no hourly charge.
- *Simplicity / fit:* a **pure backend** (RagInference, called in code as
  `raginference.genai-dev.internal:8799`) wants a DNS name, not an ALB path — and an
  ALB-fronted ECS service hits a chicken-and-egg (the target group must be
  LB-associated before the service can be created). Cloud Map matches the client
  contract, needs no listener, and is **unaffected by the `ingress_mode` toggle**, so
  east-west calls don't vanish when user ingress flips to `ssm`. *(This is a change
  from the earlier "internal ALB for RagInference" plan.)*
- *Security relaxation, stated:* plain HTTP is a deliberate, documented relaxation of
  encrypt-in-transit, acceptable only because dev carries no real data; compensating
  controls are the internal-only ALB and VPC-scoped ingress. Closing it needs a domain
  + ACM certificate (the module switches to HTTPS/TLS automatically once given one).

**Status.** Applied — ALB currently `alb` mode; RagInference reachable via Cloud Map.

**See also.** [`edge/alb/README.md`](../../infra/modules/edge/alb/README.md) (the switch
mechanics, the `aws ssm start-session` command, and the no-TLS relaxation in full),
[`networking/dns/README.md`](../../infra/modules/networking/dns/README.md) (why service
discovery, not the ALB), and
[`aws-service-consolidation.md` §2b](aws-service-consolidation.md#2b-ingress-is-switchable-alb-or-ssm-port-forwarding-2026-07-21).

---

## 5. Compute substrate

**Decision.** The app subsystems run **EC2 + docker-compose** (the workhorse pattern);
**RagInference alone** runs on **ECS Fargate (ARM64)**. **Graviton/arm64 everywhere.**
Administration is **SSM-only** (no SSH, no key pairs, IMDSv2 required). Scheduling
(scale-to-zero, overnight stop) is landed as a **separate, later** step per workload —
"land it working, then schedule it."

**Rationale.**
- *Cost:* Graviton is ~20% cheaper for equal performance. Fargate has no cluster charge
  and, once scaled to zero, no always-on line item; on-demand RagInference at
  4 vCPU/16 GB is ~$135/mo today, ~$45–57/mo on the ~10h/day schedule. RagInference runs
  **CPU, not GPU** — a GPU would add ~$380–730/mo idle for latency the product does not
  yet require.
- *Simplicity / fit:* docker-compose-on-EC2 matches how the subsystems already run
  locally, so there is minimal porting; Fargate suits RagInference because it syncs ~4 GB
  of weights at startup and fits a schedulable, stateless model server. On-demand (not
  Spot) Fargate is chosen because a single-task service can't absorb a Spot reclaim.
- *Security:* private subnets, no public IP, SSM Session Manager / ECS Exec as the only
  interactive path, KMS-encrypted EBS.

**Status.** MacroRAG EC2 (`t4g.large`) applied; RagInference Fargate applied (currently
scaled toward zero, blocked on an application-image bug tracked outside IaC).
Faultline / XbrlRag app tiers and the app-EC2 schedules are not built yet.

**See also.** [`compute/ecs-service/README.md`](../../infra/modules/compute/ecs-service/README.md)
and `compute/ec2-app/README.md`.

---

## 6. Data stores

**Decision.** **One shared customer-managed KMS key per environment** (not one per
store). **S3 secure-by-default** (public access blocked unconditionally, SSE-KMS forced,
TLS-deny policy, explicit lifecycle) for logs and the RagInference weights bucket.
**ECR with immutable tags**, scan-on-push, and image lifecycle. **Secrets Manager holds
containers only** — values are never in Terraform or state. The shared vector store is
**self-hosted Qdrant on EC2**, not Qdrant Cloud. Relational is a **single RDS Postgres**
(XbrlRag-owned, planned); MacroRAG stays **SQLite-on-EBS** — no second database.

**Rationale.**
- *Cost:* storage is negligible here, so the levers are elsewhere — one CMK (~$1/mo) vs.
  one-per-store; no S3 IA/Glacier tiering (the data is too small to bother); self-host
  Qdrant is ~$2/mo marginal (co-located) vs. a managed cluster that **bills 24/7** and
  can't ride the dev schedule.
- *Simplicity / fit:* one shared key referenced by alias keeps every store consistent;
  immutable ECR tags + git-SHA image references make deploys reproducible; a single
  RDS instead of a database per subsystem avoids idle DB spend, and MacroRAG's data
  genuinely doesn't warrant a server. Qdrant self-host wins on **data residency**
  (nothing leaves the account) and an **in-VPC hot path** (no internet/NAT dependency on
  every RAG query) — decisive precisely *because* the workload is far below managed-DB
  scale, so dollars don't decide it.
- *Security:* the Qdrant auth-off default must be closed at provisioning (API key + TLS
  + private-only SG) — tracked as a module requirement, not left to convention.

**Status.** KMS, Secrets Manager, ECR, and the S3 buckets are applied. `data/qdrant`
and `data/rds` are stubs. Qdrant **instance & placement decided 2026-07-23** — a
dedicated `t4g.small` in `30-shared-svc`, us-east-1a, *not* co-located in an app host
(shared by MacroRAG + XbrlRag) —
[`qdrant-cloud-vs-self-hosted.md` §6a](qdrant-cloud-vs-self-hosted.md#6a-decided-dedicated-t4gsmall-in-30-shared-svc-us-east-1a-2026-07-23).

**See also.** [`qdrant-cloud-vs-self-hosted.md`](qdrant-cloud-vs-self-hosted.md), and the
`security/kms`, `security/secrets`, `registry/ecr`, and `data/s3` module READMEs.

---

## 7. Cost governance

**Decision.** An account-wide **budget** ($150/mo) + **Cost Anomaly Detection** + SNS
alerts exist before meaningful spend; **mandatory `default_tags`**
(`Project`/`Environment`/`ManagedBy`, extended per resource) via the provider so cost
attribution can't be forgotten; every change states its **estimated monthly cost delta**.

**Rationale.** The cross-cutting thread of §3, §4, and §6 is one principle —
**avoid always-on line items that cannot be paused** — because at this estate size a
single unpausable resource (NAT Gateway, ALB, managed cluster) can dominate the bill.
Guardrails that alert early and tags that attribute spend make that principle
observable rather than aspirational.

**Status.** Applied (`global/cost-guardrails`).

**See also.** cost-effectiveness principle #4 in [`CLAUDE.md`](../../CLAUDE.md); the
`cost/budgets` module README.

---

## 8. Control-plane software — intended vs. built (stated honestly)

**Intended design.** A Python `iac` CLI (Typer) that orchestrates Terraform/Terragrunt
through engine subsystems (`provisioning`/`deployment`/`monitoring`/`costing`), emitting
`PipelineRun`/`StageRun` state that a **FastAPI + React operator dashboard** reads — CLI
and UI sharing one UI-agnostic engine so they never diverge.

**Actual state (important — the gap is real).** The **infrastructure and governance
layer is mature**: the Terragrunt modules, live-AWS post-apply integration tests
(`tests/integration/`), checkov/policy config, the least-privilege MCP IAM policy, and
the enforced agent-guard hooks (with their own unit tests) are production-grade and in
daily use. The **Python control plane is ~5–10% built** — only `core.config` and
`pipeline.state` are real; `provisioning`/`deployment`/`monitoring`/`costing`/`models`
are empty; the CLI commands print *"not yet implemented"*. The **operator dashboard is
pre-alpha** — a FastAPI health endpoint with routers commented out, and no frontend
beyond a scaffold note. **The "shared engine" is not yet shared**: neither the CLI
bodies nor the UI backend import the engine today.

**Rationale for the sequencing.** Provisioning is done directly via `task` / `terragrunt`
today; that is sufficient to build the estate one service at a time, so the CLI/engine/UI
are deferred until the infrastructure they would drive exists. This is a deliberate
order-of-work choice, not an omission — recorded here so the documented architecture is
never mistaken for shipped software.

**Status.** Scaffold (directory layout, data contracts, CLI surface, and task gates in
place; orchestration logic not yet written).

**See also.** `Taskfile.yml` (the real gates: `ci`, `policy`, `verify`, `plan`/`apply`);
root [`README.md`](../../README.md).

---

## 9. Deferred & open decisions

| Item | State / trigger |
|---|---|
| `staging` / `prod` environments | Empty scaffolds; stand up on demand (`00→10→20→30→apps→90/91`). |
| prod hardening toggles | RDS Multi-AZ, per-AZ NAT, **NAT Gateway in prod**, CloudFront + WAF, interface endpoints — off in dev, decided per prod need. |
| ~~Qdrant instance type & placement~~ | **Decided 2026-07-23** — dedicated `t4g.small`, `30-shared-svc`, us-east-1a ([`qdrant` §6a](qdrant-cloud-vs-self-hosted.md#6a-decided-dedicated-t4gsmall-in-30-shared-svc-us-east-1a-2026-07-23)). Build pending. |
| Domain + ACM certificate | Closes the §4 no-TLS relaxation; enables host-based routing. |
| XbrlRag rerank latency | CPU ~90s vs. GPU (`g5`) — only if narrative latency becomes a product requirement. |
| Auth perimeter | SG/ALB-only vs. OIDC/Cognito (apps have no auth today). |
| Pipeline prerequisites | SHA-based ECR tagging and making image scan results a deploy **gate** — deferred to pipeline setup. |

---

## 10. Revisit triggers

- **Qdrant** — corpus approaches ~500k–1M vectors, prod needs real HA, or quantization
  changes the RAM math ([`qdrant` §7](qdrant-cloud-vs-self-hosted.md#7-revisit-triggers)).
- **Interface endpoints** — measured NAT data-processing for any AWS service crosses
  ~162 GB/mo (§3).
- **NAT Gateway vs. instance / ALB always-on** — reconsider for `prod`, where
  availability outweighs the dev saving (§3, §4).
- **Managed services generally** — revisit only if the workload leaves the "tiny data,
  compute-and-networking-is-the-bill" regime that §0 rests on.
