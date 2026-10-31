# Runbook — Provision an environment

How to stand up the aws-genai-iac estate **from scratch** — either a brand-new AWS
account, or a new logical environment (`staging`, `prod`) inside the account that
already runs `dev`. It is the ordered, identity-gated checklist that the
provisioning scripts automate; read it before running them, and when reviewing a
provisioning change months later.

This runbook is **task-oriented**: each phase is a numbered procedure you can
follow top to bottom. It documents the real commands that exist today. Where a
phase is (or will be) wrapped by a helper script, that is called out under
[Consolidation status](#consolidation-status) rather than assumed here — the
manual commands always work.

> **Substitute your real account id** — kept only in the gitignored
> `infra/account.local.hcl` — wherever `<acct>` appears below. Never commit it.
> Placeholders (`<acct>`, `genai-<env>`) are used throughout on purpose.

## Related runbooks

- [`terraform-execution-role.md`](terraform-execution-role.md) — the identity
  model (`genai-terraform-exec` / `tfuser` / `genai-tf` profile) and the one-time
  backend bootstrap in depth. **Phase 0 below is the summary; that runbook is the
  detail.**
- [`agent-toolkit-setup.md`](agent-toolkit-setup.md) — the read-only
  `readonlyagent` identity used for live verification queries.

---

## Before you begin

Confirm you have all of the following. A missing item surfaces several phases in
as a confusing failure, not a clear one.

| Requirement | Check |
|---|---|
| Terraform + Terragrunt on PATH (or full paths per `CLAUDE.md` → *Local toolchain*) | `terraform version`, `terragrunt --version` |
| `py312` conda env with the CLI installed | `task ci` runs |
| go-task installed | `task --list` |
| **Admin** identity available for Phase 0 (the human's `<admin-profile>`, browser/`aws login` session) | `aws sts get-caller-identity` shows the admin ARN |
| **Exec-role** access configured for Phases 1–4 (`genai-tf` profile: `tfuser` → `genai-terraform-exec`) | `AWS_PROFILE=genai-tf task whoami` ends `.../genai-terraform-exec/...` |
| `infra/account.local.hcl` present with the real account id + `cost_alert_emails` (gitignored) | file exists; `monthly_budget_usd` and emails resolve |

> **Identity is not interchangeable between phases.** Phase 0 **must** run as the
> admin (the exec role cannot create itself — `iam-baseline`'s guardrail denies
> `iam:*User*`). Phases 1–4 **must** run as `genai-tf`. The `task` targets
> self-guard on the resolved STS ARN and refuse the wrong identity, so a mix-up is
> rejected, not silently applied. See the credential rule in the project
> `CLAUDE.md`.

---

## How provisioning is layered

Provisioning is not one flat command list. It is four phases that differ in **who
runs them**, **how often**, and **whether Terragrunt orders them for you**:

| Phase | What | Identity | Cadence | Ordered by |
|---|---|---|---|---|
| **0 — Account bootstrap** | State bucket, then `global/iam-baseline` (exec role + `tfuser` + boundary) | **admin** | **once per account** | this runbook (fixed, 2 steps) |
| **1 — Global baseline** | `global/cost-guardrails` (budget + anomaly detection) | `genai-tf` | once per account | this runbook |
| **2 — Environment** | Every component under `infra/environments/<env>/` | `genai-tf` | once per env, replayed on change | **Terragrunt DAG** (`dependency` blocks) |
| **3 — Post-apply data (Layer C)** | Out-of-band content: model weights, deploy bundles, secret values | `genai-tf` | per subsystem | this runbook (per-subsystem) |
| **4 — Verify** | Live-AWS post-apply assertions | `genai-tf` | after every apply | `task verify` |

Two facts follow from this table and decide everything else:

- **Phases 0–1 are per *account*, not per *environment*.** A second environment in
  the same account (`staging`) **reuses** the state bucket, the exec role, and the
  budget. You do **not** repeat Phase 0 or 1 for it.
- **Phase 2 orders itself.** Each component declares its prerequisites in
  `dependency` blocks; `terragrunt run --all` topologically sorts them. You do not
  hand-maintain an apply sequence — you maintain the dependency edges. The
  `00-/10-/20-/30-/40-` folder-number prefixes are human-readable documentation of
  the same order; Terragrunt orders by the graph, not the folder name.

> **Terraform state does not replicate an environment.** State is a per-component
> snapshot bound to one account's real resource ids; it gives you idempotence
> (re-apply is a no-op) and drift detection, not a build-from-scratch script. The
> reproducibility guarantee lives in the **code + the DAG**, which is why this
> runbook plus `terragrunt run --all` is the reconstruction mechanism — not a state
> copy.

---

## Choose your path

**New AWS account** → run **Phase 0 → 1 → 2 → 3 → 4** in order.

**New environment in the existing account** (`staging`, `prod`) → Phase 0 and 1 are
already done. Start at **Phase 2**, then **3**, then **4**.

---

## Phase 0 — Account bootstrap (admin, once per account)

Creates the two things the exec role cannot create for itself. Run as your **admin**
identity. Full rationale: [`terraform-execution-role.md`](terraform-execution-role.md)
→ *One-time bootstrap*.

**To bootstrap a new account:**

1. **Provide the account values.** Create `infra/account.local.hcl` (gitignored)
   with the real account id, and the cost-alert email addresses:

   ```hcl
   locals {
     account_id        = "<acct>"                 # real 12-digit id — never committed
     cost_alert_emails = ["you@example.com"]
   }
   ```

2. **Create the Terraform state backend.** Chicken-and-egg: the S3 state bucket
   must exist before any `terragrunt` run.

   ```bash
   # as the ADMIN identity
   AWS_REGION=us-east-1 STATE_BUCKET=aws-genai-iac-tfstate scripts/bootstrap-backend.sh
   ```

   The `s3:CreateBucket` / `PutBucketVersioning|Encryption|PublicAccessBlock` verbs
   are intentionally **not** on the exec role, which is why this is an admin step.

   > **Important:** re-running the current script on an existing bucket errors on
   > `create-bucket`. On a re-provision, skip this step (the bucket persists) or run
   > the idempotent wrapper once it exists — see [Consolidation status](#consolidation-status).

3. **Apply the IAM baseline.** Creates `genai-terraform-exec`, its scoped policies,
   the `genai-app-boundary`, and `tfuser`.

   ```bash
   # as the ADMIN identity — NOT genai-tf (the role cannot create itself)
   task iam-baseline
   #   └► cd infra/environments/global/iam-baseline && terragrunt apply
   ```

   `task iam-baseline` refuses to run if it detects the exec role, so an
   accidental `AWS_PROFILE=genai-tf` here is blocked.

4. **Configure the `genai-tf` profile** so Phases 1–4 can assume the exec role.
   One-time per machine; see
   [`terraform-execution-role.md`](terraform-execution-role.md) → *Steady state* for
   the exact `~/.aws/config` + `~/.aws/credentials` entries. Confirm:

   ```bash
   AWS_PROFILE=genai-tf task whoami   # must end .../genai-terraform-exec/...
   ```

> **Admin-apply-before-commit gate.** Phase 0 is the human checkpoint in the project
> `CLAUDE.md`. Do not commit or push any change that depends on an un-applied Phase 0
> step until it is applied and verification passes.

---

## Phase 1 — Global baseline (exec role, once per account)

**To create the account-wide cost guardrails:**

1. Set the exec-role profile: `export AWS_PROFILE=genai-tf` (PowerShell:
   `$env:AWS_PROFILE = "genai-tf"`).

2. Apply the budget + Cost Anomaly Detection. It must exist **before** the first
   meaningful spend (a provisioning principle), and costs ~$0/month itself:

   ```bash
   terragrunt apply --working-dir infra/environments/global/cost-guardrails
   ```

The budget ceiling comes from `monthly_budget_usd` in `account.hcl`; alert emails
come from `account.local.hcl` (the component fails validation if they are absent —
a budget nobody is told about is not a guardrail).

---

## Phase 2 — Environment provisioning (exec role, per environment)

This is Layer B: the whole `infra/environments/<env>/` tree, ordered by the DAG.

**To provision an environment:**

1. **Author the environment tree (first time only).** The `staging` and `prod`
   trees are skeletons (`.gitkeep`) until populated. Create:
   - `infra/environments/<env>/env.hcl` — set `name`, `name_prefix`
     (`genai-<env>`), a **non-overlapping** `vpc_cidr`, and `ingress_mode`.
   - Each component `terragrunt.hcl` as a thin copy of the `dev` equivalent,
     pointing at the same `infra/modules/*`. All names are already
     env-parameterized (`genai-${env}-...`), so copies are mechanical **except**
     values hardcoded inline — image SHA tags, per-component AZ pins — which must
     be set for the new environment.

   > Land these copies one component at a time under the usual flow
   > (module reuse → `task ci` → `task policy` → plan → apply → verify → commit),
   > not as one giant paste.

2. **Set the exec-role profile:** `export AWS_PROFILE=genai-tf`.

3. **Read the plan, do not skim it.** Any `destroy`/`replace` stops the work and is
   surfaced to a human before apply:

   ```bash
   task plan ENV=<env>
   #   └► terragrunt run --all --working-dir infra/environments/<env> -- plan
   ```

4. **Apply.** Terragrunt walks the dependency DAG in order — foundation
   (networking → security → data → shared services) before the application leaves:

   ```bash
   task apply ENV=<env>
   #   └► terragrunt run --all --working-dir infra/environments/<env> -- apply
   ```

   To provision a **single subsystem** rather than the whole environment, target its
   subtree — but only once its shared foundation is already applied (Terragrunt reads
   real dependency outputs from state; `mock_outputs` cover `plan`/`validate` only).
   See the [worked example](#example-stand-up-raginference-on-staging).

---

## Phase 3 — Post-apply data steps (exec role, per subsystem)

Layer C is the out-of-band content that Terraform provisions a *container* for but
does not fill: an S3 bucket exists empty, a Secrets Manager secret exists valueless.
These steps are **per subsystem** and are run after that subsystem's Phase 2
components apply. Run as `genai-tf` unless noted.

| Subsystem | Post-apply step | Command |
|---|---|---|
| RagInference | Seed model weights into the weights bucket (empty until seeded) | `python scripts/seed_raginference_weights.py` |
| MacroRAG | Upload the docker-compose deploy bundle to the corpus `deploy/` prefix | `python scripts/deploy_macrorag_bundle.py --source <MacroRAG checkout>` |
| MacroRAG | Populate the app secret **value** (the `10-security/secrets` component creates the empty container; the value is put out-of-band) | see the MacroRAG deployment notes |
| XbrlRag / Faultline | Not built yet — each records its own step here when validated | — |

> **Append discipline.** A subsystem's post-apply step is part of its
> definition-of-done: add its row here (and its `postdeploy` module — see
> [Consolidation status](#consolidation-status)) in the **same** change that lands
> and verifies the subsystem, so the step never becomes tribal knowledge.

Each script is idempotent (skips objects already present, re-runs safely) and
writes KMS-encrypted objects via the bucket's default SSE-KMS — pass no explicit
SSE header, or the bucket policy's KMS guard rejects the put.

---

## Phase 4 — Verify

Success from `apply` means Terraform got a 200, not that the resource is correct.
Verify against the live AWS API.

```bash
AWS_PROFILE=genai-tf task verify ENV=<env>
#   └► pytest tests/integration -m integration
```

`task verify` refuses to run unless it resolves the exec role, so a silent skip
cannot masquerade as a pass. If verification is skipped for any reason, say so —
do not report the change as done.

---

## Reference: component dependency order

The apply order for an environment, as encoded in the `dependency` blocks (the
foundation is shared by every subsystem; the leaves are per-subsystem):

```
FOUNDATION (shared)
  kms ─┬─► logs-bucket ─► vpc ─┬─► subnets ─┬─► endpoints
       │                       │            └─► nat ─► nat-schedule
       │                       ├─► dns
       │                       └─► security-groups
       └─► ecr, secrets

LEAVES (per subsystem — each independently appliable once the foundation exists)
  kms ─► 20-data/raginference-weights ─► 30-shared-svc/raginference ─► (schedule)
  kms ─► 20-data/macrorag-corpus ──────► 41-macrorag/app ───────────► (schedule)
  ... 40-quantlibpricer, 42-arag ...
```

Regenerate this view from the source of truth at any time:

```bash
grep -rA2 'dependency "' infra/environments/<env> --include=terragrunt.hcl \
  | grep -E 'dependency "|config_path'
```

---

## Example: stand up RagInference on `staging`

A worked, subsystem-granular reconstruction. Assumes Phase 0 and 1 are already done
for the account (they are shared).

```bash
export AWS_PROFILE=genai-tf              # exec role — never admin for Layer B/C
D=infra/environments/staging

# Phase 2a — shared FOUNDATION (needed by every subsystem; apply once for staging)
terragrunt run --all --working-dir $D/00-networking -- apply   # vpc, subnets, dns, sg, endpoints
terragrunt run --all --working-dir $D/10-security   -- apply   # kms (+ secrets)
terragrunt apply --working-dir $D/20-data/ecr                  # shared ECR (holds the raginference repo)

# Phase 2b — RagInference-SPECIFIC leaves
terragrunt apply --working-dir $D/20-data/raginference-weights
terragrunt apply --working-dir $D/30-shared-svc/raginference

# Phase 3 — Layer C: seed the weights (bucket is empty until now)
python scripts/seed_raginference_weights.py --env staging

# Phase 4 — verify against live AWS
task verify ENV=staging
```

> RagInference's security-group rule and its ECR repository live inside the
> **shared** `security-groups` and `ecr` components, not a raginference-only folder.
> Provisioning the subsystem therefore necessarily applies those shared components —
> the practical unit is *"shared foundation (once) + subsystem leaf (per subsystem)."*
> Running the whole environment with `task apply ENV=staging` achieves the same result
> and lets the DAG order everything; the targeted form above is for standing up or
> re-applying one subsystem in isolation.

---

## Forking: names that must change

S3 bucket names are global across all AWS accounts, so a fork cannot reuse this
repo's names. There is no single switch for the `genai` prefix. It also scopes the
exec role's S3 access, so changing it in one place fails later with `AccessDenied`.
Change all of these together:

| What | Where |
|---|---|
| State bucket | `state_bucket` in `infra/account.local.hcl`, and `STATE_BUCKET` for the bootstrap scripts |
| IAM scoping | `name_prefix` in `infra/environments/global/env.hcl` |
| Environment prefix | `name_prefix` in `infra/environments/<env>/env.hcl` |
| Bucket names | `bucket_name` in each `infra/environments/<env>/20-data/*/terragrunt.hcl` |
| Script defaults | the `--bucket` defaults in `scripts/deploy_*.py`, `scripts/seed_raginference_weights.py`, and `scripts/postdeploy.py` |
| Verification | the names asserted in `tests/integration/` |

## Consolidation status

Which phases are automated today, and which are still a documented sequence of
manual commands. This runbook stays authoritative for order and rationale; the
scripts wrap it.

| Phase | Today | Planned consolidation |
|---|---|---|
| 0 — Account bootstrap | `scripts/bootstrap-backend.sh` + `task iam-baseline` (two commands) | `scripts/bootstrap-account.sh` — one idempotent, admin-gated script (create-if-not-exists backend, then `iam-baseline`) |
| 1 — Global baseline | `terragrunt apply … global/cost-guardrails` | folded into the Phase-2 driver (still exec role) |
| 2 — Environment | `task apply ENV=<env>` (already consolidated by the DAG) | no change — Terragrunt owns ordering |
| 3 — Post-apply data | one script per subsystem, invoked by hand | `scripts/postdeploy/<subsystem>.py` behind a `scripts/postdeploy.py --env <env> --subsystem <name>` dispatcher; one module added as each subsystem is validated |

Keep Phase 0 in its **own** script, separate from Phases 1–4: the identity handoff
(admin → `genai-tf`) and the admin-apply-before-commit human gate must stay between
them. A single script spanning both identities would defeat the credential model.
