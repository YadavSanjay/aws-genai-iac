# XbrlRag subsystem — AWS rollout plan (`42-arag`)

Status: planning (2026-07-25) · Owner decisions locked below · Source of truth for
XbrlRag's application requirements: `XbrlRag/docs/design/ARag_AWS_Deployment_Plan_July2026.md §6`.

XbrlRag is the next subsystem after the shared services (RagInference, Qdrant) and
MacroRAG. Faultline follows XbrlRag (it depends on XbrlRag). This plan follows the
project rule of **one service per change** — each chunk below is its own
`module → tests → task ci → plan → apply → verify → commit` cycle.

## Reconciliation — the XbrlRag application doc is partly superseded

The XbrlRag deployment plan was written 2026-07-16, before this repo's shared-services
and ingress decisions. Where they conflict, **this repo wins**:

| XbrlRag doc assumes | This repo's reality | Consequence |
|---|---|---|
| XbrlRag runs its own Qdrant EC2 + RagInference EC2 | **Shared** Qdrant + RagInference live in `30-shared-svc`; XbrlRag gets an `arag` Qdrant collection | XbrlRag **consumes** them (see `docs/guides/consuming-shared-services.md`), does not provision them — large scope cut |
| Public ALB + ACM as entry point | dev `ingress_mode=ssm` (ALB torn down) | UI reached via SSM port-forward, like MacroRAG; ALB/ACM deferred to a prod public-ingress phase |
| Separate UI EC2 + separate svc EC2 | MacroRAG proved the single-host multi-container compose pattern | **Decision: single compose host in dev** (below) |

The one genuinely net-new infra piece is **RDS Postgres** — XbrlRag owns `xbrl_db`, and
the `data/rds` module is unbuilt.

## Locked decisions (2026-07-25)

- **Topology → single compose host in dev.** `ui` (nginx) + `api` + `mcp` as containers
  on one `ec2-app` instance. The XbrlRag doc's separate-UI-EC2 isolation argument is a
  prod/public-ALB concern; dev is SSM-only. Revisit for prod.
- **Ingest runner → on-demand EC2 (Option A).** A stopped `arag-ingest` EC2 (full image
  + Arelle + JRE), started via SSM when needed, operator runs the documented CLI.
  Graduate to Fargate/Batch (Option B) only if UI-button-triggered ingest is wanted.
- **RDS → scheduled stop/start 11:00–21:00 ET, single-AZ.** `db.t4g.micro/small`,
  scheduled down off-hours like the app hosts. Ingest/DDL must run in-window; RDS start
  takes a few minutes. No Multi-AZ in dev.
- **Auth perimeter → SG-to-SG + SSM only for dev** (app has no auth; the network is the
  boundary). OIDC/Cognito is a prod-exposure concern, tracked, not built now.

## Rollout chunks (dependency-ordered)

| # | Chunk | Component | Notes | Std monthly cost delta (dev, scheduled) |
|---|---|---|---|---|
| **A1** | ECR repos | `20-data/ecr` | ✅ done — `arag`, `arag-ui`, `arag-ingest` added. | ~$0 (storage only) |
| **A2** | S3 filings bucket | `20-data/arag-filings` | ✅ done — mirrors `macrorag-corpus`: SSE-KMS CMK, block-public, TLS-deny, versioned, durable, lifecycle. Ingest-side only. | ~$0 (tiny data) |
| **A3** | Secrets | `10-security` | ✅ done — `genai-dev/arag/app` = `OPENAI_API_KEY` + `JINA_API_KEY` (KEY=value); per-secret reader deny (as MacroRAG). **DB password NOT here** — RDS uses an AWS-managed master-user secret (A4). | +$0.40 (1 secret) |
| **A4** | RDS Postgres 16 | new `data/rds` module + `42-arag/db` | ✅ done — Postgres 16 `db.t4g.micro`, CMK storage, engine-enforced TLS (`rds.force_ssl=1`), single-AZ, `manage_master_user_password` (credential never in state), CMK+retention log export, `genai-dev-rds` SG. Needed an admin exec-role grant (`CreateSecret` on `rds!*`). DB empty until the A7 DDL bootstrap. | ~$6–12 + $2.30 gp3 |
| **A5** | Security groups | `networking/security-groups` | Largely **absorbed**: the `rds` SG shipped with A4, and XbrlRag reuses the shared `app` SG (already egresses to Qdrant/RagInf/RDS, all admit it). Only the ingest runner's own SG/ingress remains → folded into A7. | $0 |
| **A6** | XbrlRag app tier | `42-arag/app` | ✅ done — `ec2-app` compose ui+api+mcp (`arag` + `arag-ui`) live & verified (10/10, containers healthy); RDS + shared Qdrant/RagInf wired; **IMDS hop 1** (boto3-free container); SSM ingress; no data volume + no RW S3. Needed an admin boundary grant (`GetSecretValue` on `rds!*`) for the RDS-managed secret. `deploy_arag_bundle.py` ships the app bundle. | ~$6–10 (t4g.small ~10h/day) |
| **A7** | Ingest runner + DDL bootstrap | `42-arag/ingest` | on-demand EC2 (stopped by default), **runs the `arag-ingest` image** (deployed here, NOT via the app bundle — separate lifecycle); one-time RDS DDL (`scripts/ddl/*` → `rebuild_mvs.py`) as a runbook. **Validate CL #4d here** (entry_url coupling → silently empty vector load in S3 mode) on live DB + real Arelle. | ~$0 idle (started ad-hoc) |
| **A8** | Schedule | `42-arag/app` + `42-arag/db` | ✅ done — app host 11:00–21:00 (mirror of qdrant/macrorag), and the **database 10:45–21:10**, bracketing it so RDS is `available` before the host boots and outlives it on the way down. **Both windows now live inside their own components**, so each target is a reference and cannot go stale; the app's separate `42-arag/app-schedule` was retired 2026-07-29 once `ec2-app` gained `start_cron`/`stop_cron`. Needed an admin boundary grant (`rds:Start/StopDBInstance`) — without it the role is capped to nothing and the schedule silently no-ops. | −$6.65/mo on the DB; app folded into A6 |

## Application code status (XbrlRag repo)

Mostly AWS-ready — CL #1–#7, #9 done (Qdrant env fix, `ARAG_DEPLOY_MODE`, `FilingStore`,
`boto3` ingest-only, Postgres TLS, `Dockerfile.ingest`, docs). Two open, both surface in A7:

- **CL #4d — `entry_url` coupling (deferred).** In S3 mode Arelle runs on a localized temp
  path and writes that into `entry_url`; `relative_to(sec_edgar_root)` then fails and every
  filing is skipped → a **silently empty vector load**. Fix = persist a stable rel-key at
  ingest and resolve canonical HTML from it in all three read stages. Must be validated
  end-to-end on the ingest EC2.
- **CL #8 — CI push to ECR (deferred).** Needs the active ECR repos from A1; wire the
  build/push job (SHA-tagged, per the pipeline-prerequisites note) when A1 lands.

## Open items (tracked, not blocking dev)

- RagInference sizing for XbrlRag narrative latency (~90s CPU rerank for ~30 docs) — CPU
  scale-to-zero today; GPU (`g5`) only if it becomes a product requirement.
- RDS credentials: static password from Secrets Manager now; RDS IAM-auth tokens later.
- Prod hardening (RDS Multi-AZ, per-AZ NAT, CloudFront+WAF, ALB+ACM, OIDC) — off in dev.
