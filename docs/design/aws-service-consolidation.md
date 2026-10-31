# AWS Service Consolidation Plan

Status: approved (decisions recorded 2026-07-17) · Scope: IaC service inventory
for the four sibling subsystems (Faultline, MacroRAG, XbrlRag, RagInference).

Source of truth for each subsystem's raw requirements:
- Faultline — `AITrade_aws_deployment_design.md` §8
- MacroRAG — `Macro_RAG_AWS_Deployment_Plan.md` §4
- XbrlRag — `ARag_AWS_Deployment_Plan_July2026.md` §6
- RagInference — `aws-deployment-plan.md` §7

## 1. Headline finding

None of the four subsystems use **Bedrock, SageMaker, a managed vector DB, or
EKS**. "AI" is: external LLM APIs (OpenAI/Anthropic over HTTPS egress) +
**self-hosted models** (RagInference: BGE-M3 embedder + Jina reranker, CPU-only)
+ **self-hosted Qdrant**. The dominant compute substrate is **EC2 + docker-compose**;
only RagInference runs on **ECS Fargate**. Data is tiny-to-moderate (Faultline
= 36 MB total; RagInference = ~4 GB weights), so **compute + networking are the
entire bill** — storage is negligible.

## 2. Approved cost-optimization decisions

| Lever | Decision |
|---|---|
| RagInference GPU | **No GPU** — CPU Fargate ARM64 (avoids ~$380–730/mo idle GPU). |
| RagInference / batch runtime | **Scale-to-zero by default** — RagInference scheduled 1↔0 off-hours; XbrlRag ingest + Faultline VaR on Spot + scale-to-zero. |
| Public ingress | **One shared ALB** (currently internal, switchable — §2b), path-based routing; **RagInference uses Cloud Map** service discovery, not an ALB (§2c). |
| Vector store | **Shared Qdrant** (one EC2, `arag` + `macrorag` collections, int8 quantization) — analysis in [`qdrant-cloud-vs-self-hosted.md`](qdrant-cloud-vs-self-hosted.md). |
| Egress | **One shared single-AZ NAT** + S3 gateway endpoint (free). ⚠️ **REVISED 2026-07-20** — see §2a. |
| Relational | **Single RDS Postgres 16** (XbrlRag-owned). MacroRAG stays SQLite-on-EBS — no 2nd DB. |
| Dev spend | Instance scheduling (stop app EC2s off-hours). |

## 2a. Egress revision — NAT instance, not NAT Gateway (2026-07-20)

The original decision was a managed NAT Gateway. Two findings during rollout
changed it.

**NAT Gateway cannot be paused.** It bills $0.045/hour for every hour it
*exists*, regardless of traffic — there is no `stop` state. The only way to
suspend the charge is to delete and recreate it, which means new gateway IDs and
route-table rewrites on every cycle.

**That directly conflicts with the scale-to-zero decision in §2.** Dev stops its
app EC2s off-hours (~36% uptime). A NAT Gateway running 24/7 would then be the
*largest single line item in dev* — larger than all the application compute it
exists to serve:

| | Running | Stopped | Monthly |
|---|---|---|---|
| App EC2s (scheduled off) | ~$70 | $0 compute | ~$25 |
| NAT Gateway | $32.85 | $32.85 | **$32.85** |

**Revised decision.** A `t4g.nano` NAT instance, started and stopped on the same
schedule as the app EC2s. It has EC2 semantics, so it genuinely stops; the ENI
persists, so the private route table needs no automation.

| Approach | 24/7 | Scheduled (~36%) |
|---|---|---|
| NAT Gateway | $32.85 | $32.85 (unpausable) |
| NAT GW + delete/recreate automation | — | ~$11.70 + route-rewrite complexity |
| **NAT instance `t4g.nano`** | ~$7.31 | **~$3** |

~91% cheaper. Uses an auto-assigned public IP rather than an Elastic IP — it
changes on restart, which is irrelevant for outbound-only NAT since nothing
allowlists our egress address.

**Accepted costs:** we own patching, and it is a single point of failure. Both
acceptable in dev. **prod keeps the NAT Gateway**, where an unattended 3am
failure costs more than the $26/month saved.

**Also revised:** interface endpoints (ECR/Secrets/Logs) are dropped from dev.
At $7.30/month each, three of them cost ~$22/month to avoid NAT data-processing
charges that amount to pennies at dev volume — break-even is roughly 162 GB per
month *per service*. The S3 **gateway** endpoint stays: it is free, and since
ECR image layers live in S3 it removes the bulk of container-pull traffic from
the NAT path anyway. Revisit interface endpoints for prod on measured volume.

**Sequencing:** NAT is deferred out of the networking phase entirely. Nothing
needs egress until the first workload lands, so building it earlier would mean
paying for an empty VPC.

## 2b. Ingress is switchable: ALB or SSM port forwarding (2026-07-21)

**Requirement:** every application must be reachable two ways, with the ability
to switch between them — because the window in which the subsystems need to work
*together* through a shared ALB is much narrower than the window in which they
are being developed individually.

| Mode | Cost | Reach | Use when |
|---|---|---|---|
| `alb` | **$16.43/mo**, unpausable | Public URL, host/path routing | Subsystems must interoperate, or an external user needs access |
| `ssm` | **$0.00** | `localhost` tunnel, AWS creds required | Everything else — solo development on one subsystem |

**Why this matters.** An ALB cannot be stopped. It bills 24 hours a day for an
application scheduled to run ten — the same shape as the NAT Gateway problem in
§2a. At the current estate size a permanently-on ALB would be roughly 75% of
total spend, serving an app that is off most of the time.

SSM port forwarding needs no new infrastructure (the hosts are already managed
nodes), exposes nothing publicly, and requires AWS credentials — which during
build-out is exactly the right audience:

The switch mechanics — the `aws ssm start-session` port-forward command, what the
destroy/recreate plan looks like, why security groups are deliberately *not* toggled,
and the tested round trip — are the authoritative "how" in
[`edge/alb/README.md`](../../infra/modules/edge/alb/README.md). In short: `ingress_mode`
in each environment's `env.hcl` gates only the billable resources (load balancer,
listeners, target groups); flipping to `ssm` destroys them and applications fall back to
an SSM tunnel, and the switch is a version-controlled change, so an environment's
ingress state is always visible in git.

**Applies to the user-facing app tiers** — MacroRAG, XbrlRag and Faultline register as
targets of the shared ALB and become unreachable-except-by-SSM together when the mode
flips. **RagInference is the exception** — a pure backend reached via Cloud Map, not the
ALB, and so unaffected by `ingress_mode` (§2c).

### No domain yet — no TLS

With no registered domain, ACM cannot issue a certificate, so the ALB serves **plain
HTTP** with **path-based** (not host-based) routing. This is a deliberate, documented
relaxation of encrypt-in-transit, acceptable only because dev carries no real data; the
compensating controls and the two ways to close it (register a domain + ACM cert, or
restrict `alb_ingress_cidrs`) are detailed in
[`edge/alb/README.md`](../../infra/modules/edge/alb/README.md#no-domain-therefore-no-tls).

## 2c. East-west discovery is Cloud Map, not the internal ALB (revised 2026-07-21)

The original plan (§2, §3) fronted RagInference with a second, *internal* ALB. That was
dropped in favor of **Cloud Map private DNS** (`networking/dns`). A pure backend called
by sibling services in code wants a DNS name (`raginference.genai-dev.internal:8799`),
not an ALB path; a namespace is ~$0.50/mo with no listener and no hourly charge; and an
ALB-fronted ECS service hits a chicken-and-egg (the target group must be LB-associated
before the service can be created). Crucially, discovery is **unaffected by the §2b
`ingress_mode` toggle** — east-west calls must not disappear when user ingress flips to
`ssm`. The internal ALB is retained only for app tiers that genuinely need path-based
HTTP routing; the ALB's short-lived "external target group" support was reverted.
Full rationale:
[`networking/dns/README.md`](../../infra/modules/networking/dns/README.md).

## 3. Cross-subsystem service matrix

| Service | Faultline | MacroRAG | XbrlRag | RagInference | Strategy |
|---|:--:|:--:|:--:|:--:|---|
| VPC / subnets / SG | ✓ | ✓ | ✓ | ✓ | one shared VPC, ≥2 AZ |
| NAT egress | ✓ | ✓ | ✓ | avoid | one shared single-AZ **NAT instance** (§2a) |
| S3 gateway endpoint | ✓ | ✓ | ✓ | ✓ | shared (free) |
| ALB + ACM | ✓ | ✓ | ✓ | Cloud Map | one shared ALB (internal, switchable §2b); RagInference via Cloud Map (§2c) |
| EC2 (compose app) | c7i.xlarge | t3.large | t3.large/xl | — | per-subsystem, SG-isolated |
| ECS Fargate | — | — | — | ✓ ARM64 | RagInference only |
| Qdrant (EC2+EBS) | — | ✓ | ✓ | — | shared, 2 collections |
| RDS Postgres 16 | shared | ✗ SQLite | ✓ | — | single instance |
| S3 buckets | qlp-data | corpus | filings | weights | 4 buckets, one module |
| ECR | ✓ | ✓×2 | ✓×3 | ✓ | one module, many repos |
| Secrets Manager | ✓ | ✓ | ✓ | ✓ | shared module |
| IAM roles | ✓ | ✓ | ✓ | ✓ | per-tier least-privilege |
| CloudWatch logs/alarms | ✓ | ✓ | ✓ | ✓ | baseline |
| SQS | ✓ | ✗ | opt | ✗ | Faultline |
| On-demand job runner | VaR | ✗ | ingest | ✗ | Spot / scale-to-zero |
| Route53 private zone | ✓ | ✓ | ✓ | ✓ | `*.internal` discovery |
| AWS Backup | — | EBS snap | RDS+EBS | — | stateful stores |
| EventBridge Scheduler | opt EOD | ✗ | opt MV refresh | ✗ | optional |
| EFS / ElastiCache / CloudFront / WAF | opt | opt Redis | opt | opt EFS | deferred toggles |

## 4. Module changes vs. initial scaffold — ✅ applied to the scaffold

All the directory-level changes below are **done**: the DROP targets no longer
exist, the REPLACE and ADD directories are all present. Retained for rationale.
Note this describes *directories*, not implementations — see §5 for build status.

**KEEP** — `networking/vpc`, `networking/endpoints` (expand to interface endpoints),
`security/iam`, `security/kms`, `data/s3`, `data/rds`, `observability`,
`cost/{budgets,anomaly-detection,tags}`, `compute/ecs-service` (→ RagInference Fargate).

**DROP** — `compute/eks`, `ai/bedrock`, `ai/sagemaker` (no managed AI anywhere).

**REPLACE** — `ai/opensearch-vector` → `data/qdrant`.

**DEFER (stub)** — `compute/lambda`, `data/dynamodb`, `security/guardrails`
(single account → no SCPs).

**ADD** — `compute/ec2-app` (the workhorse, was missing), `edge/alb`,
`registry/ecr`, `security/secrets`, `networking/dns`, `messaging/sqs`,
`compute/job-runner` (Spot/ECS-RunTask, scale-to-zero), `data/backup`,
`scheduler/eventbridge` (optional).

## 5. Environment component layout (dependency-ordered)

> **STATE NOTE (reconciled 2026-07-29).** The `dev` estate below is **built end to
> end** over a real project VPC (`10.10.0.0/16`), and `global` is applied. Every
> layer from `00-networking` through `42-arag` is live, plus `90-observability`
> (ops alert topic + EventBridge Scheduler alarms). The `data/qdrant` and
> `data/rds` modules named as unbuilt in the previous revision both shipped.
>
> **`91-cost` is the one unbuilt layer**, and deliberately so: `global/cost-guardrails`
> already carries the account budget and Cost Anomaly Detection, so a per-env layer
> only earns its keep once dev/staging/prod carry distinguishable spend.
>
> The authoritative live-component status is the table on the
> [status page](../status.md); this section records the *plan and
> dependency ordering*, not a state snapshot. `staging`/`prod` remain empty scaffold
> directories with no `env.hcl` — not appliable, and a decision to make rather than a
> plan already in motion.

```
environments/{dev,staging,prod}/
├── 00-networking/   # VPC, subnets, NAT, S3+interface endpoints, Route53, shared ALB
├── 10-security/     # IAM baseline, KMS, Secrets Manager
├── 20-data/         # RDS Postgres, S3 buckets, ECR repos
├── 30-shared-svc/   # RagInference (Fargate ARM64) + Qdrant (EC2)  ← all depend on this
├── 40-quantlibpricer/  # app EC2 + SQS + optional VaR job-runner
├── 41-macrorag/        # app EC2 (+ EBS)
├── 42-arag/            # app EC2 + ingest job-runner
├── 90-observability/   # CloudWatch dashboards/alarms (AMP/AMG optional)
└── 91-cost/            # budgets, anomaly detection, tag policy
```

Rollout order: `00→10→20` foundation, `30` shared services, then `42`(XbrlRag, owns
RDS) → `41` → `40`, finally `90/91`.

## 6. Open items to revisit
- XbrlRag RagInference latency: CPU rerank ~90s; GPU (`g5`) only if narrative latency
  becomes a product requirement (currently CPU, scale-to-zero).
- XbrlRag auth perimeter: SG/ALB-only vs OIDC/Cognito (app has no auth).
- prod hardening toggles: RDS Multi-AZ, per-AZ NAT, CloudFront+WAF — off in dev.
- Region choice (us-east-1 vs us-east-2): **list price is a wash** — both are the
  same AWS pricing tier; every service's On-Demand/storage rate is identical
  (verified against public price files for Secrets Manager, KMS, VPC endpoints,
  ECR; documented parity for EC2/EBS/Fargate/RDS/NAT/ALB/S3/DTO). So the choice
  is operational, not cost:
  - **Spot** is the only region-variable cost — market prices move independently;
    us-east-2 typically has less contention / fewer interruptions, a mild plus for
    the scale-to-zero Spot runners (Faultline VaR, XbrlRag ingest).
  - **Blast radius** — us-east-1 is AWS's busiest region and outage epicenter;
    us-east-2 is the common greenfield pick to avoid it.
  - **CloudFront caveat** — if the deferred CloudFront+WAF toggle is enabled, its
    ACM cert **must** live in us-east-1 regardless of the app region (one extra
    us-east-1 cert if the rest runs in us-east-2; no cost impact).
  - Currently pinned to `us-east-1` (`infra/account.hcl`). No price reason to
    switch; only switch (pre-bootstrap) if blast-radius/Spot behavior is a priority.
