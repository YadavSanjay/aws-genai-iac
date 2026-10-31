# Current status

What is applied, what is scaffolded and what is still open. The root [README](../README.md) gives
the overview; this page is the detail.

> **The `dev` estate is currently PARKED** (`parked = true` in
> [`infra/environments/dev/env.hcl`](../infra/environments/dev/env.hcl), applied 2026-07-31).
> Everything below is provisioned and verified, and nothing is running: the daily windows are
> disabled, RagInference is bounded to zero tasks, and the database is held down by a stop-only
> schedule. This drops the estate from ~$4/day to ~$0.68/day between demos. Waking it up is a flag
> flip and an apply, **not** a re-provision. See [park mode](design/park-mode.md) for the reasoning
> and [runbook §11](runbooks/day2-operations.md#11-park-the-environment-and-wake-it-up) for the
> commands.

## Environments

**Target model:** a single AWS account with multiple **logical** environments
(`dev` / `staging` / `prod`) isolated by name prefix, tags and separate VPCs. Terragrunt keeps
backend and provider config DRY across per-component state files.

**Today:** `environments/dev/` is **applied end-to-end** (networking → security → data → shared
services → the MacroRAG, XbrlRag and Faultline app tiers → observability) over a dedicated project
VPC (`10.10.0.0/16`), and `environments/global/` is applied (IAM baseline, cost guardrails).
`staging` and `prod` exist only as empty scaffold directories (no `env.hcl`, not yet appliable).

When not parked, everything that can be scheduled is: the NAT runs 10:00–22:00 ET, the four EC2
tiers 11:00–21:00, and the XbrlRag database 10:45–21:10 (bracketing its app tier, because RDS takes
~8 minutes to reach `available`). Nothing in `dev` bills 24×7 except storage.

## What is applied

| Area | State |
|---|---|
| State backend (S3, versioned, SSE-KMS) + S3-native locking | applied |
| `global` — IAM baseline (exec role, 5 policies, boundary, `tfuser`) + cost guardrails (budget, anomaly detection) | applied |
| `dev/00-networking` — VPC, subnets, S3 gateway endpoint, scheduled NAT instance, security groups, private Cloud Map DNS | applied |
| `dev/10-security` — shared KMS CMK, Secrets Manager | applied |
| `dev/20-data` — ECR repos (12), logs bucket, RagInference weights / MacroRAG corpus / XbrlRag filings buckets | applied |
| `dev/30-shared-svc` — RagInference on ECS Fargate (Cloud Map service discovery, scale-to-zero off-hours) | applied |
| `dev/30-shared-svc` — shared Qdrant vector store (dedicated `t4g.small`, us-east-1a, Cloud Map TLS, CMK data volume, 11:00–21:00 schedule) | applied — deployed & verified healthy ([`qdrant` §6a](design/qdrant-cloud-vs-self-hosted.md#6a-decided-dedicated-t4gsmall-in-30-shared-svc-us-east-1a-2026-07-23)) |
| `dev` ingress | `ssm` mode — app tiers reached via SSM port-forward; the shared ALB is torn down (no LB in dev) |
| `dev/41-macrorag` — MacroRAG app tier (4-container compose stack on EC2, S3 corpus + CMK data volume, 11:00–21:00 schedule) | applied — validated end-to-end |
| `dev/42-arag` — XbrlRag app tier (`ui`+`api`+`mcp` compose on EC2), RDS Postgres 16 (CMK, TLS-enforced, managed master secret), on-demand ingest runner | applied — app tier and database verified, corpus ingested, and both on a daily window (host 11:00–21:00, database 10:45–21:10) ([rollout plan](design/arag-rollout-plan.md)) |
| `dev/40-quantlibpricer` — Faultline app tier | applied — Q1–Q6 live and verified (ECR ×3, `qlp-data` bucket, secret, app→app reachability, `t4g.large` app host on an 11:00–21:00 window) ([rollout plan](design/quantlibpricer-rollout-plan.md)) |
| `dev/90-observability` — ops alert topic + EventBridge Scheduler alarms | applied — every scheduled start/stop is now watched: `TargetErrorCount` and `InvocationDroppedCount` publish to a confirmed subscriber |
| `91-cost` layer | not built — `global/cost-guardrails` already carries the account budget and anomaly detection |
| Python `iac` CLI/engine + operator dashboard | scaffold — see [design-decisions §8](design/design-decisions.md#8-control-plane-software--intended-vs-built-stated-honestly) |

The **why** behind these choices (cost, simplicity and fit to the workload) is the
[design-decisions record](design/design-decisions.md).

Six module dirs remain DEFER/README stubs with no consumer: `compute/{job-runner,lambda}`,
`messaging/sqs`, `data/{backup,dynamodb}` and `security/guardrails`.

## Outstanding work (paused 2026-07-29)

The `dev` estate is complete apart from `91-cost`. What remains is listed here so it is a decision
rather than tribal knowledge; nothing below blocks the running system.

**Layers not built**

| Item | Why it is still open |
|---|---|
| `91-cost` | `global/cost-guardrails` already carries the account budget and Cost Anomaly Detection. A per-env layer only earns its keep once dev/staging/prod carry distinguishable spend. `cost/tags` and `cost/anomaly-detection` sit unreferenced and want reconciling with it. |
| `90-observability`, continued | The alert channel and scheduler alarms are live. Still missing: resource alarms (EC2 status checks, RDS CPU/storage/connections, data-volume disk), a dashboard, and folding RagInference's inline ECS alarms into the module so there is one definition rather than two. |
| `staging` / `prod` | Empty scaffolds with no `env.hcl`. The largest unbuilt thing in the repo — and if multi-env is not actually wanted, they are worth deleting rather than implying a plan. |

**Open against infrastructure that already exists**

| Item | Note |
|---|---|
| Faultline on-host verification | Containers on the app host never confirmed via SSM. Needs a human: `readonlyagent` cannot SSM, and carries explicit denies on `ecr:BatchGetImage` and `s3:GetObject`, so neither image architecture nor the deployed tags are readable by the agent. |
| MacroRAG `cp`-hardening | Recorded as unapplied drift; confirm with a `terragrunt plan` on `41-macrorag/app`. |
| Qdrant auth (phase 2) | Deliberate dev relaxation — close before the store holds anything real. |
| XbrlRag narrative rerank latency | jina-v3 on CPU exceeds the timeout. Cheapest fix is seeding `bge-reranker-v2-m3` and flipping `RERANKER=bge` service-side — an ECS task-env change, no host reprovision. |
| ECR immutable SHA tags + image-scan deploy gate | Deferred to pipeline work. |
| `test_cost_guardrails.py` | Asserts on SNS's `SubscriptionsConfirmed` counter, which lags reality by minutes. `test_ops_alerts.py` shows the fix: read `list_subscriptions_by_topic` instead. |
| NAT and Qdrant schedules | Left as separate `*-schedule` components by decision, unlike the app tiers. `test_schedule_targets.py` guards them against the stale-target failure. |
