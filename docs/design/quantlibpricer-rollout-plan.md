# Faultline subsystem — AWS rollout plan (`40-quantlibpricer`)

> Faultline was formerly **QuantLibPricer**. The component path (`40-quantlibpricer`) and the
> `qlp-*` resource names keep the old name deliberately — renaming them would orphan Terragrunt
> state / force resource replacement.

Status: planning (2026-07-27) · Owner decisions locked below · Source of truth for
Faultline's application requirements:
`faultline/docs/design/AITrade_aws_deployment_design.md` (§7 topology, §8 service
inventory, §9 the phased change list).

Faultline is the last of the four sibling subsystems, and follows XbrlRag because it
**consumes** XbrlRag (and MacroRAG) over the network. This plan follows the project rule of
**one service per change** — each chunk below is its own
`module → tests → task ci → plan → apply → verify → commit` cycle.

## Where the application already is

Unusually for this estate, the app side is ahead of the infrastructure. Phases A–D of
the Faultline design are **delivered on its `main`**:

| Phase | What landed | Why it matters here |
|---|---|---|
| **A** | `src/common/storage/` dual-mode façade — `PRICER_DEPLOY_MODE` (`local`\|`aws`) + `PRICER_DATA_URI`; every read/write in marketdata, pricer, risk, scenariogen, sizing and governance routes through it | S3 is a config flip, not a code project |
| **B** | `src/common/jobs/` — `JobRunner` Protocol, `LocalSubprocessRunner`, `AwsJobRunner` (SQS **enqueue**), storage-backed `JobRecordStore` | the seam exists; **no worker consumes the queue yet** |
| **C** | three images — `qlp-backend` (python:3.12-slim + QuantLib PyPI wheel), `qlp-bff` (no QuantLib), `qlp-ui` (nginx-unprivileged SPA); `docker-compose.aws.yml`; committed `.env.example` | the deploy contract is already written and matches `compute/ec2-app` |
| **D** | `PRICER_API_KEY` `X-API-Key` middleware on the pricer API (no-op when unset) | in-app defence-in-depth for an SSM-only tier |

**Phase E of that document is this component.** The endpoints it needs
(`ARAG_BASE_URL`, `MACRORAG_BASE_URL`, `RAGINFER_URL`, `QLP_SERVICE_URL`,
`QLP_CORS_ORIGINS`, `API_UPSTREAM`) are already `${VAR:-default}`-driven, so wiring is
configuration, not code.

## Reconciliation — the Faultline design doc is partly superseded

That document was written 2026-07-16, before this repo's shared-services, ingress and
single-host decisions. Where they conflict, **this repo wins**:

| QLP doc assumes | This repo's reality | Consequence |
|---|---|---|
| ALB + ACM as the public front door (§7.1, §7.4) | dev is `ingress_mode = "ssm"` — the shared ALB is torn down | UI reached by SSM port-forward, like MacroRAG and XbrlRag. ALB/ACM/WAF are a prod public-ingress phase |
| Separate UI/edge instance + separate backend instance (Decisions 1–2) | MacroRAG and XbrlRag both proved the single-host multi-container compose pattern | **one `ec2-app` host** runs `backend` + `bff` + `ui`. The tier-isolation argument is a public-ALB concern; dev has no public tier to isolate |
| EFS mount for the shared data tree (§7.3) | 36 MB of data on one host does not justify an always-on line item | **CMK EBS data volume**, mounted into both containers |
| Its own RAG tier instance (Decision 3) + its own Qdrant/RDS (Decision 4) | `30-shared-svc` already runs RagInference and Qdrant; XbrlRag owns the RDS | Faultline provisions **none** of it — it consumes XbrlRag and MacroRAG as running app tiers |
| `c7i.xlarge` x86 backend (§7.1) | Graviton is the estate default | **arm64 `t4g.large`**, gated on the golden-PV suite passing in the built image (below) |

The one genuinely net-new infra piece is **app-tier-to-app-tier reachability** — the
analogue of XbrlRag's RDS. Everything else is an instance of a pattern already in the repo.

## Locked decisions (2026-07-27)

- **Scope → serving stack only.** One `ec2-app` compose host (`backend` + `bff` + `ui`),
  SSM ingress. Heavy work (full-reval VaR, market-data ingest) runs on that box via
  Session Manager. **No SQS and no second instance in v1** — the `AwsJobRunner` enqueues
  but nothing in the Faultline repo consumes the queue, so provisioning one now
  would create a queue with no reader.
- **Data plane → CMK EBS data volume is the live tree; S3 is seed + backup.**
  `PRICER_DEPLOY_MODE=local` against the mount, so behaviour is byte-identical to the
  laptop and the BFF's DuckDB read path works unchanged. A `qlp-data` bucket is the
  off-box copy the tree is seeded from and pushed back to — **both directions manual, by
  decision (2026-07-29): the operator syncs by hand after runs.** Automating it is
  scoped and deliberately unbuilt (see Open items); native S3 is CL-Q10.

  **Where a run actually lands, and what it survives.** `scenariogen`, pricing and risk
  outputs are written by the backend to `/mnt/qlp-data/` on the CMK data volume —
  `scenariogen/snapshots/` and `pricer/store/{scenario,scenario_results,scenario_llm,`
  `signoff,versions,runs,results,spans}/`. That volume survives container restarts, the
  daily 21:00 stop, **and** instance replacement (a separate `aws_ebs_volume`, not
  delete-on-termination — `test_qlp_app` asserts it). What it does **not** survive is
  loss of the volume itself, so until an operator pushes to S3 a run exists in exactly
  one place.
- **Architecture → arm64 (Graviton). VERIFIED 2026-07-28, not merely reasoned.**
  QuantLib 1.42.1 publishes a `cp38-abi3 manylinux_2_28_aarch64` wheel, which covers
  Python 3.12 via the stable ABI and installs without a source build. Measured on a
  `linux/arm64` container:

  | Check | Result |
  |---|---|
  | Pinned probe (option / bond / swap analytics), x86_64 vs aarch64 | **10 of 14 values bit-identical**; worst difference **5.93e-16 relative** (3 ULP), only on `exp`/`log`/`erf` paths |
  | Faultline's own golden-PV governance gate (`tests/pricer/test_governance.py`) | **8 passed** |
  | Full pricer suite (`tests/pricer`, incl. the multiprocess full-reval VaR) | **264 passed**, 0 failed, 0 skipped |

  The worst observed drift sits ~1.7×10⁹ inside the `rel_tol=1e-6` gate, and the whole
  bond and swap block — discounting, yield solving, duration, convexity, fair-rate
  solving — is bit-for-bit identical. The 801-step binomial American option lands within
  3 ULP, so iterative paths do not accumulate meaningfully either.

  **Caveat: that was qemu emulation, not Graviton silicon.** Emulation reproduces
  IEEE-754 double semantics faithfully, so the *arithmetic* transfers; the ~1 hour
  wall-clock does **not** — read no VaR performance signal from it. CL-Q5 therefore
  stands as a build gate on the real image, but it is now confirming a measured result
  rather than testing an assumption.
- **RAG wiring → REST dual-RAG only.** `ARAG_BASE_URL` / `MACRORAG_BASE_URL` point at new
  private DNS names. The **agentic MCP flow stays local-only**: its client spawns XbrlRag and
  MacroRAG as stdio subprocesses from local repo checkouts (`ARAG_HOME=<xbrlrag-checkout>`),
  which has no cloud analogue without a code change (CL-Q3).
- **Auth perimeter → SG-to-SG + SSM only**, as for every other dev tier.
  `PRICER_API_KEY` and `QLP_WRITE_TOKEN` are set anyway as defence-in-depth.

## The net-new piece: app-to-app reachability

Faultline is the first subsystem that calls **another app tier** rather than a
shared backend service, and that path does not exist today:

- **No name.** `compute/ec2-app` registers nothing in the private zone. Qdrant and
  RagInference are reachable (`qdrant.<ns>.internal`, `raginference.<ns>.internal`)
  because their modules create a Cloud Map service; the app hosts have only a private IP
  that changes on every reprovision.
- **No route.** The shared `app` security group admits ingress **from the ALB only**. Two
  hosts in that group cannot talk to each other, in either direction.

Both XbrlRag and MacroRAG publish their API on host port **8000** (XbrlRag additionally serves
MCP on 8765; both serve their UI on 8080), so a single port opens both.

**Approach (Q4).** Two small additive changes, in this order:

1. `networking/security-groups` — a **self-referencing** app→app rule pair on 8000
   (`referenced_security_group_id` = the app SG itself, never a CIDR). This is a
   security-group change only; no instance is touched.
2. `compute/ec2-app` — an **optional** `service_discovery_namespace_id` +
   `discovery_service_name`, creating `aws_service_discovery_service` +
   `aws_service_discovery_instance` from the instance's private IP. This mirrors exactly
   what `data/qdrant` already does. The resources are additive and reference
   `aws_instance.app.private_ip` — they do **not** alter user-data or the instance, so
   applying it to the live MacroRAG and XbrlRag hosts must plan as *add-only*.

**Why registration lives in the module and not in a component of its own.** This is the
maintainability decision, and it is the same one the `app-schedule` components got wrong.
A separate component would hold a *copy* of another component's output, so re-applying the
host without also re-applying that component leaves the record pointing at a dead
instance — which is exactly why a schedule can end up pinned to a terminated instance id.
Registering inside `ec2-app` makes the record a *reference* (`aws_instance.app.private_ip`)
in the same state, so Terraform's graph rewrites it in the same apply that replaces the
instance. The stale window does not exist, rather than being short. A VPC instance also
keeps its private address across stop/start, so the 11:00–21:00 schedule never churns it.

The only remaining way to desync is changing the instance outside Terraform, which the
no-click-ops rule already forbids — and `test_app_discovery.py` fails on it, because the
runtime symptom does not: a stale A record still resolves, and the caller simply times out
as though the remote application were broken.

A dedicated ENI (a private IP that outlives the instance entirely) was considered and
**rejected**: it solves a problem that no longer exists once registration is in-module, it
forces the security groups onto the ENI at `device_index 0`, and adopting it would replace
both live hosts — breaking this chunk's own add-only condition.

> **Stop condition.** If the `41-macrorag/app` or `42-arag/app` plan shows anything other
> than `N to add, 0 to change, 0 to destroy`, stop and surface it. A replacement there
> costs those hosts their local state, and — per the XbrlRag rollout — **also orphans their
> `app-schedule` component**, which pins the old instance id.

## Rollout chunks (dependency-ordered)

| # | Chunk | Component | Notes | Monthly cost delta (dev, scheduled) |
|---|---|---|---|---|
| **Q1** | ECR repos | `20-data/ecr` | ✅ done — `qlp-backend`, `qlp-bff`, `qlp-ui` created (6 add / 0 / 0): CMK-encrypted, `IMMUTABLE` tags, scan-on-push, untagged-3d + keep-5 lifecycle. `test_ecr` 9/9 live, now also covering `raginference`/`qdrant` (previously unasserted) and failing on any undeclared repository. | ~$0 until pushed, then ~$0.30–0.60 |
| **Q2** | S3 data bucket | `20-data/qlp-data` | ✅ done — `genai-dev-qlp-data-us-east-1` (7 add / 0 / 0): SSE-KMS CMK + bucket keys, block-public, ACLs off, TLS + non-KMS deny, versioned, no live expiry, no transitions, 30d noncurrent, 7d MPU. Holds the seed/backup of the 36 MB data tree **and** the `deploy/` bundle prefix. `test_qlp_data` 14/14 live, including a **behavioural** negative control (an AES256 upload is actually refused) with a positive control proving the refusal comes from the bucket policy and not from a missing grant. | ~$0 (MB-scale) |
| **Q3** | Secret | `10-security/secrets` | ✅ done — `genai-dev/qlp/app` (2 add / 0 / 0): CMK-encrypted, 7d recovery, `KEY=value` env-file form, per-secret reader deny excepting **only** `genai-dev-qlp`. Keys: `PRICER_API_KEY`, `QLP_WRITE_TOKEN`, `OPENAI_API_KEY`, `FRED_API_KEY` (see CL-Q7 — **not** `PRICER_FRED_API_KEY`). `test_secrets` 12 passed / 1 skipped, the skip being the value hand-off. Includes a **behavioural** check that the deny genuinely refuses the exec role, not merely that it is attached. **Value set by the human before Q5.** | +$0.40 (4 secrets, $1.60 total) |
| **Q4a** | App→app SG rule | `networking/security-groups` | ✅ done — self-referencing ingress + egress on 8000 (2 add / 0 / 0, no group replaced, no existing rule touched). SG-referenced, never CIDR. `test_security_groups` 13/13 live; the "ingress from the ALB only" assertion was **tightened**, not relaxed — it now pins the source set to exactly {ALB, app} and the port range to exactly 8000, so a third source or a widened range fails. Relaxation documented in the module README. | $0 |
| **Q4b** | App-host service discovery | `compute/ec2-app` (+ re-apply `41-macrorag/app`, `42-arag/app`) | ✅ done — `arag.genai-dev.internal` → 10.10.133.37 and `macrorag.genai-dev.internal` → 10.10.140.161, TTL 10, both confirmed as real Route53 records in the private zone. Both components planned and applied **2 add / 0 change / 0 destroy**, so neither live host was replaced; `test_arag_app` 10/10 and `test_macrorag_instance` 16/16 still green afterwards. New `test_app_discovery` 4/4 including the drift check. | $0 (namespace is free) |
| **Q5** | App tier | `40-quantlibpricer/app` | ✅ applied 2026-07-29 (7 add / 0 / 0) — `i-0aee...`, `10.10.140.237`, role `genai-dev-qlp`. `ec2-app`, arm64 `t4g.large`, 30 GB root + **10 GB CMK data volume**, three ECR repos on `arm64-ec72173`, app secret → `/opt/qlp/.env`, deploy bundle from the `qlp-data` bucket, SSM ingress. **IMDS hop 1**, not 2: in `local` mode the containers make no AWS calls (the S3 seed/sync is host-side), so the role stays off the docker bridge; switching to `PRICER_DEPLOY_MODE=aws` would require 2. `test_qlp_app` **11/11 live**, `task ci` 127 green, checkov 535/0. Ships `scripts/deploy_qlp_bundle.py` + the `deploy.env` template. **On-host container check outstanding** (human SSM step). | ~$23.6 (t4g.large ~10h/day + 40 GB EBS) |
| **Q6** | Schedule | `40-quantlibpricer/app` — **not** a separate component | ✅ applied 2026-07-29 (4 add / 0 / 0 — role, policy, start, stop; the instance untouched). 11:00–21:00 `America/New_York`. `compute/ec2-app` gained `start_cron`/`stop_cron`/`schedule_timezone`/`schedule_enabled` and instantiates `scheduler/eventbridge` as a **nested module**, so the target is `aws_instance.app.id` rather than a copied id. Required switching all three `ec2-app` consumers to the `//` subdir source (MacroRAG and XbrlRag both planned **No changes**). `test_qlp_schedule` **5/5** live. | (folded into Q5) |

**Estimated total: ~$25/month**, of which ~$20 is the instance's scheduled hours. Nothing
here adds an always-on charge: no NAT, no load balancer, no EFS, no queue, no database.

Sizing note: `t4g.large` is 2 vCPU, so `PRICER_WORKERS=2`. QuantLib's
`ql.Settings.evaluationDate` is process-global, so VaR parallelism is process-level —
more cores is the only lever, and the step up to `t4g.xlarge` (~$40/mo scheduled) is a
one-line change if the measured VaR wall-clock justifies it. Right-size on evidence.

## Verification (per chunk, against the live API as `readonlyagent`)

New `tests/integration/` modules alongside the existing `test_arag_*.py` set:

- `test_qlp_data_bucket.py` — encryption, public-access block, TLS-deny and non-KMS-deny
  policy statements, versioning, lifecycle (mirrors `test_arag_filings.py`).
- `test_security_groups.py` (extend) — app→app on 8000 exists and is SG-referenced; a
  negative assertion that no CIDR rule opens 8000.
- `test_app_discovery.py` — `arag.` and `macrorag.` resolve in the namespace to the
  current instance IPs.
- `test_qlp_app.py` — instance private + SSM-managed, role reads **only** the qlp secret
  and the three ECR repos, data volume is CMK-encrypted, no public IP, containers up.

Plus the on-host checks (human, via Session Manager): `docker ps` all three healthy,
`/health` and `/api/health` 200, the SPA loads over an SSM port-forward, and one live
`scenariogen` call that actually reaches XbrlRag and MacroRAG.

## Prerequisites the human owns (out of band) — ALL FOUR BLOCK Q5's APPLY

Verified outstanding as of 2026-07-27: all three ECR repos are empty, the secret has no
version, and the bucket's `deploy/` prefix has no objects.

1. **Build and push three arm64 images** to the Q1 repos, SHA-tagged (never `:latest`) —
   with the golden-PV suite green inside the `qlp-backend` image (CL-Q5).
   Registry: `<acct>.dkr.ecr.us-east-1.amazonaws.com/genai-dev/qlp-{backend,bff,ui}`.
2. **Set the `genai-dev/qlp/app` secret value.** `KEY=value` lines: `PRICER_API_KEY`,
   `QLP_WRITE_TOKEN`, `OPENAI_API_KEY`, `FRED_API_KEY` (the last two un-prefixed —
   CL-Q7). The bootstrap renders this under `set -euo pipefail`, so an unset value
   aborts the boot before the image pull with nothing on disk explaining why.
3. **Fix CL-Q8 in the Faultline repo**, then **upload the deploy bundle**:
   `AWS_PROFILE=genai-tf python scripts/deploy_qlp_bundle.py --tag arm64-<sha>`.
   Uploading before the compose forwards the east-west endpoints ships a stack that
   cannot reach XbrlRag or MacroRAG.
4. **Seed the data tree — MANUAL, both directions** (decision 2026-07-29). The
   `ec2-app` bootstrap syncs the deploy *bundle* only; it has no data-seed step, so a
   fresh volume comes up empty and stays empty. Push up from the laptop, then pull down
   on the host over SSM:
   ```
   aws s3 sync data/ s3://genai-dev-qlp-data-us-east-1/data/            # laptop -> S3
   sudo aws s3 sync s3://genai-dev-qlp-data-us-east-1/data/ /mnt/qlp-data/   # S3 -> host
   sudo aws s3 sync /mnt/qlp-data/ s3://genai-dev-qlp-data-us-east-1/data/   # host -> S3
   ```
   The instance role already carries the S3 grant, so no extra credentials are needed.
   **Deliberately not automated:** a seed-on-boot input would be rendered into user-data,
   and `user_data_replace_on_change = true` makes that *replace the host* — not worth it
   for a step run rarely, on a volume that already survives replacement.

Sequence: 1–3 in any order, then apply Q5, then `test_qlp_app.py`, then the on-host SSM
checks, then 4 and the end-to-end `scenariogen` run (which additionally needs the XbrlRag
ingest to have populated its database).

## Faultline repo change list (tracked; none block Q1–Q4)

- **CL-Q1 — the BFF's data mount is `:ro`.** `docker-compose.aws.yml` mounts the tree
  read-only into `bff`, but the BFF owns four gated writes (limits, sign-off, jobs,
  sizing-activate). Either mount it `rw` in dev or accept those four endpoints failing.
  **Surfaces at Q5.** This is also what blocks a native `PRICER_DEPLOY_MODE=aws` v1.
- **CL-Q2 — image tags ride `deploy.env`, never Terraform.** The compose file already
  reads `${QLP_BACKEND_IMAGE}` etc., so this is a tooling gap, not a design one: it needs
  a `scripts/deploy_qlp_bundle.py` mirroring `deploy_arag_bundle.py`, and the host must
  fetch the pointer with `aws s3 cp`, **not** `s3 sync` (two SHA tags are the same length,
  so `sync` skips the change — this has bitten twice). Per CLAUDE.md provisioning
  principle 6.
- **CL-Q3 — agentic MCP flow is stdio-only.** `configs/scenariogen/llm/mcp.json` launches
  XbrlRag and MacroRAG from local checkouts. XbrlRag already serves MCP over HTTP on 8765, so
  the cloud path exists on the server side; the client needs streamable-HTTP support, and
  MacroRAG needs to serve MCP at all. **Deferred** — the deterministic REST dual-RAG path
  is unaffected.
- **CL-Q4 — CORS.** `QLP_CORS_ORIGINS` must include the SSM-tunnel origin
  (`http://localhost:<forwarded-port>`), not an ALB hostname.
- **CL-Q5 — golden PVs are the arm64 build gate**, per the architecture decision above.
- **CL-Q10 — the BFF cannot read S3, so the backend must NOT be flipped to `aws` mode.**
  The clean end state is one source of truth in S3, no sync in either direction, and a
  **stateless** app host with no data volume at all. The blocker is measured, not
  suspected: `ui/bff/app/settings.py:38-41` discards a remote URI outright —
  `if uri and "://" not in uri: return Path(uri)` — and falls back to `project_root()/
  "data"`; the readers in `stores.py` are pure local filesystem (`Path.glob()`,
  `duckdb read_parquet('<posix path>')`, `p.stat().st_mtime`); and the BFF imports nothing
  from `src/common/storage`, so it never sees the façade. Setting
  `PRICER_DEPLOY_MODE=aws` today would have the backend write to S3 while the BFF kept
  reading a volume nobody writes to — **a permanently blank UI, failing silently**.
  Work required: move the ~15 DuckDB reader modules onto fsspec/`s3fs` globs, give DuckDB
  `httpfs` + `credential_chain`, replace `st_mtime` ordering with object metadata, add
  `s3fs` to the BFF image, and resolve CL-Q1's `:ro`/gated-writes question on the way.
  Already tracked app-side as §7.6 / the Phase-A follow-on note. When it lands, the flip
  is a one-line `runtime_env` change (which replaces the host) and `data_volume_gb` can
  go to 0.
- **CL-Q8 — the compose does not forward the east-west endpoints.** `docker-compose.aws.yml`
  passes only `PRICER_DEPLOY_MODE`, `PRICER_DATA_URI`, `PRICER_ENV`, `PRICER_LOG_LEVEL` and
  `PRICER_JSON_LOGS` into the backend container. `ARAG_BASE_URL`, `MACRORAG_BASE_URL`,
  `RAGINFER_URL` and `PRICER_WORKERS` are set in Q5's `runtime_env` but never reach the
  container, so `scenariogen` would fall back to its `localhost:8001` / `localhost:8000`
  defaults and fail against nothing. They are non-secret, so they belong in the compose
  `environment:` block, **not** in the secret env-file. **Blocks Q5's apply.**
- **CL-Q7 — `.env.example` documents the wrong FRED variable.** It lists
  `PRICER_FRED_API_KEY`, but that name belongs to `src/pricer/settings.py`, whose own
  docstring says the pricing module needs no key today. The downloaders read the
  **un-prefixed** `FRED_API_KEY` through `marketdata.common.settings.load_credentials()`
  (that settings class declares no `env_prefix`). Since a missing source key only
  *disables* that source, setting the documented name would leave market-data ingest
  keyless and silent. Q3's secret uses the un-prefixed name; the app repo should either
  fix the example or have `PlatformSettings` alias it. The same applies to the five other
  source keys (`STOOQ_API_KEY`, `FINRA_API_KEY`, `FINRA_API_KEY_SECRET`, `EIA_API_KEY`,
  `OPENFIGI_API_KEY`), which can join the same secret without an infra change.
- **CL-Q6 — mount paths must agree.** `ec2-app`'s `data_mount_point` (default
  `/mnt/data`), the compose file's `${QLP_DATA_MOUNT:-/mnt/qlp-data}`, and
  `PRICER_DATA_URI` all name the same tree. Set `QLP_DATA_MOUNT` via `runtime_env` — the
  compose `${VAR}` interpolation reads the CLI `--env-file`, which is the lesson from
  XbrlRag's A6.

## Dependency on XbrlRag

The infrastructure dependency is only **reachability**, and XbrlRag's app tier is live — so
Q1–Q6 can land now. The *functional* dependency is deeper: XbrlRag's RDS has schema but no
facts until its ingest runs, so Faultline's dual-RAG evidence path will return empty
until then. Sequence the end-to-end `scenariogen` validation after the XbrlRag ingest;
everything before it is independent.

## Open items (tracked, not blocking dev)

- **SQS + a backend worker** for the BFF's job-submit path — needs a consumer in the
  Faultline repo first. The `messaging/sqs` and `compute/job-runner` modules are
  still README-only stubs.
- **On-demand VaR runner** — if VaR wall-clock on `t4g.large` proves unacceptable, the
  `compute/ingest-runner` pattern (normally-stopped instance, started via SSM) transfers
  directly.
- **Automatic volume → S3 sync** (the "Q7" that was scoped and deliberately not built).
  An `aws_ssm_association` running `aws s3 sync /mnt/qlp-data/ s3://<qlp-data>/data/` on a
  schedule, targeted **by tag** so it survives instance replacement. It needs no new IAM
  (the instance role already has the grant, the CLI is installed, SSM agent is attached),
  costs $0, and — critically — touches neither user-data nor the instance, so it plans as
  add-only. **Deferred by decision (2026-07-29): the operator syncs by hand after runs.**
  If built later: **no `--delete`** on the push-back, or an empty/unmounted volume would
  mirror its emptiness onto S3 (versioning makes that recoverable for 30 days, which is
  not a thing to rely on); and run it *before* the 21:00 stop, not merely periodically.
- **Native BFF-over-S3 → then flip the backend** — the genuinely clean end state, and the
  one that removes syncing in **both** directions. See **CL-Q10**; gated on CL-Q1 too.
  Until it lands, `PRICER_DEPLOY_MODE=aws` must **not** be set: the backend would write to
  S3 while the BFF kept reading the volume nobody writes to, blanking the UI.
- **NAT and Qdrant keep their separate `*-schedule` components — decided 2026-07-29,
  not an oversight.** MacroRAG's and XbrlRag's were folded into their app components
  because `compute/ec2-app` already supported it. NAT and Qdrant are built on
  `networking/nat-instance` and `data/qdrant`, so folding them needs the same nested-module
  support added to *those* modules plus the `//` source change — two module changes for a
  failure that is now **caught** rather than silent: `tests/integration/
  test_schedule_targets.py` fails if any schedule targets an instance that no longer
  exists. Revisit if either module is being touched anyway. Note the residual risk is not
  symmetric: a stale Qdrant schedule takes the shared vector store down for MacroRAG, XbrlRag
  **and** Faultline, whereas a NAT left running costs pennies on a `t4g.nano`.
- **Prod hardening** — ALB + ACM + WAF, OIDC/SSO at the edge, multi-AZ. Off in dev.
