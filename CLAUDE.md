# aws-genai-iac — agent guide

IaC control plane for AWS GenAI workloads. Python CLI over Terraform/Terragrunt,
plus a FastAPI + React operator dashboard.

## Git workflow — commit directly to `main`

**This project works on `main` only. Do NOT create feature branches.** This
overrides the global "if on the default branch, branch first" rule: for this repo
the agent commits directly to `main`, without asking each time, once a change is
applied and verified. **Only the human pushes.** The agent's GitHub token is
read-only, so when work is committed, say so and leave the push to the human.

- The trigger to commit is unchanged: land a change per the one-service-at-a-time
  flow (module → tests → `task ci` → plan → apply → **verify** → commit).
  Commit at real checkpoints, not mid-change.
- The **admin-apply-before-commit** gate still holds: never commit/push a change that
  depends on an un-applied admin AWS step until the human has applied it and
  verification passes. "Work on `main`" changes *where* commits land, not *when*.
- Standard commit hygiene still applies — no `Co-Authored-By` or other AI attribution,
  `git commit -F`/heredoc for multi-line messages, no bare `#N` issue refs.

## Conventions
- **Terraform:** reusable logic lives ONLY in `infra/modules/`. `infra/environments/`
  holds thin Terragrunt composition (`terragrunt.hcl` + `*.hcl` locals) — no raw
  resource blocks. Every module ships `main.tf variables.tf outputs.tf versions.tf README.md`.
- **Root Terragrunt config is `infra/root.hcl`** (NOT `terragrunt.hcl` — a root file
  with that name is a deprecated Terragrunt anti-pattern). Components include it via
  `include "root" { path = find_in_parent_folders("root.hcl") }`; the bare no-arg
  `find_in_parent_folders()` form does not work here.
- **Remote state:** one S3 bucket, one key per component, derived from the folder path
  and normalized to forward slashes (Windows otherwise writes literal backslashes into
  the S3 key, so a POSIX shell or CI would miss the state). Locking is **S3-native**
  (`use_lockfile = true`) — there is no DynamoDB lock table.
- **Single account, logical envs:** `dev`/`staging`/`prod` are isolated by name
  prefix + tags + separate VPCs, not separate accounts.
- **Python:** engine in `src/iac/` is UI-agnostic. The CLI (`src/iac/cli`) and the
  UI backend (`ui/backend`) both import the engine — never duplicate logic.
- **Secrets** never go in `config/` or tfvars — use SSM Parameter Store / Secrets Manager.
- **No sensitive identifiers in committed files or docs.** Never write the real AWS
  account id, access keys, ARNs carrying the real account id, or other account-specific
  secrets into documentation, code comments, runbooks, or any committed file. Use
  placeholders (`<acct>`, `AKIA...`, `arn:aws:iam::<acct>:...`). The real account id lives
  ONLY in the gitignored `infra/account.local.hcl`. This applies to everything written,
  including examples. `scripts/check_public_safe.py` enforces this in `task lint` and
  pre-commit.

## Provisioning principles — how we build out real AWS infrastructure

These govern every change that creates or modifies live AWS resources. They are
core guiding principles, not suggestions.

### 1. One service at a time

**Never provision more than one AWS service per change.** Land it, verify it, then
move to the next. If a service is complex (VPC, EKS, Bedrock+RAG stacks), break it
into smaller independently-appliable chunks — e.g. VPC → subnets/route tables →
endpoints → security groups, each its own module + plan + apply + verify cycle.

The unit of work is: *module → tests → `task ci` → `plan` (read the diff, don't skim
it) → `apply` → post-apply verification → commit*. A plan that shows resources
outside the service under construction means the change is too big; split it.

### 2. Tests are real, never mocked

**Every change ships tests, and they exercise real behavior.** For infrastructure
that specifically means:

- **Post-apply verification against the live AWS API** is the primary test — query
  the resource that was actually created (via the MCP server as `readonlyagent`)
  and assert on its real configuration: encryption on, public access blocked,
  policy as intended, tags present.
- **`terraform plan` assertions** — parse real plan JSON (`terraform show -json`)
  and assert on it. Not a hand-written fixture pretending to be a plan.
- **Policy-as-code on real config** — `checkov` / `tflint` over the actual modules.
- **Negative tests** — assert the thing that *should* be denied is denied (e.g. a
  public-read PUT to the bucket fails, the exec role cannot touch IAM users).
- Python engine code gets real unit tests; fakes are allowed **only** at a defined
  interface seam per the global convention, and never to fake away the assertion
  the test exists to make. A test that only proves a mock was called is not a test.

Do not mark a change done on the strength of a successful `apply`. Apply success
means Terraform got a 200; it does not mean the resource is configured correctly
or securely. Verify, then report — and if verification was skipped, say so.

### 3. Security is watertight, and enforced by checks

Convention alone is not security — every rule below needs a mechanical check
(checkov policy, tflint rule, module-level `validation` block, or a test) so it
cannot be silently violated later.

Defaults for every resource, no exceptions without a written rationale:

- **Encrypt at rest** (KMS; prefer a CMK for data stores, AWS-managed only for
  low-value/ephemeral) and **in transit** (TLS enforced via resource policy —
  `aws:SecureTransport` deny).
- **No public exposure by default.** S3 public access block on; no `0.0.0.0/0`
  ingress; no public subnets for anything that does not require one; databases and
  internal services in private subnets only.
- **Least privilege, always.** No `*` in `Action` or `Resource` on an IAM policy
  that survives review. Scope by ARN and condition-gate where possible. Prefer
  roles over users, short-lived credentials over static keys.
- **No secrets in code, state, or logs.** SSM Parameter Store / Secrets Manager,
  fetched at runtime. Mark Terraform outputs `sensitive` where relevant.
- **Logging and audit on by default** — CloudTrail, access logs, VPC flow logs
  (sampled if cost demands), retention set explicitly.
- **Blast-radius limits** — the exec role's permissions boundary stays intact;
  new roles created by IaC carry the boundary too.

When a security control is deliberately relaxed, it is stated in the module README
with the reason and the compensating control. Silent relaxation is a defect.

### 4. Cost-effective by default

Cost is a design constraint from the first line, not a cleanup pass. Pick the
cheapest option that meets the requirement, and say what it costs.

- **Serverless / on-demand first.** Lambda, Fargate Spot, DynamoDB on-demand,
  S3 + Athena, Bedrock on-demand — before anything with a 24×7 hourly charge.
- **Beware the always-on line items.** NAT Gateway, ALB/NLB, EKS control plane,
  provisioned Bedrock throughput, idle RDS, VPC endpoints. Each needs a reason.
  Prefer **VPC gateway endpoints** (S3/DynamoDB — free) over NAT for AWS-service
  traffic; a single NAT in dev, not one per AZ.
- **Graviton (arm64)** wherever supported — ~20% cheaper for equal performance.
- **Lifecycle everything that accumulates** — S3 lifecycle rules to IA/Glacier or
  expiry, CloudWatch log group `retention_in_days` set explicitly (never the
  "never expire" default), ECR image expiry.
- **Right-size down, scale up on evidence.** Smallest viable instance/memory;
  autoscale rather than over-provision.
- **`dev` is not `prod`** — single-AZ, no read replicas, aggressive shutdown, short
  retention. Reserve HA/multi-AZ spend for `prod`.
- **Everything is tagged for cost attribution** (see below), a budget + alarm exists
  before the first meaningful spend, and any resource that can be torn down when
  idle, is.
- Every non-trivial change states its **estimated monthly cost delta** in the
  commit/PR body. "Cheap" is not a number.

### 5. Greenfield AWS baseline practices

Apply these to every new service unless there is a stated reason not to:

- **Mandatory tags on every resource** — `Project`, `Environment`, `Owner`,
  `ManagedBy=terraform`, `CostCenter`. Set via the provider `default_tags` so it
  cannot be forgotten; enforce with a check. *Known gap:* `infra/root.hcl` sets
  `Project`, `Environment` and `ManagedBy=terragrunt` today, with no `Owner` or
  `CostCenter` and no check yet.
- **Consistent naming** — `<project>-<env>-<component>` prefix, since envs share one
  account and the prefix *is* the isolation boundary here.
- **Idempotent, reproducible, no click-ops.** If it exists in AWS and not in code,
  it is drift — import it or delete it. Never fix a problem in the console.
- **Pin versions** — Terraform, providers, and modules pinned; the lockfile is
  committed. *Known gap:* modules declare floors today (`>= 1.8`, `>= 5.50`) and
  `.terraform.lock.hcl` is gitignored, so this is the target, not the current state.
- **Plan output is read, not skimmed.** Any `destroy` or `replace` in a plan stops
  the work and gets surfaced to the human before apply.
- **Prod resources carry `prevent_destroy`** / deletion protection; dev does not.
- **Design for failure** — timeouts, retries with backoff, DLQs on async paths,
  health checks. Multi-AZ in prod for anything stateful.
- **Observability at creation time**, not later — CloudWatch alarms on the handful
  of signals that matter (errors, throttles, latency, cost), structured logs, and
  wire into the existing metrics/trace surfaces rather than bypassing them.
- **Least-privilege networking** — security groups reference other security groups,
  not CIDRs, wherever possible; default-deny NACLs; no wide-open egress on
  sensitive workloads.
- **Every module ships a README** stating purpose, inputs/outputs, the security
  posture, and the cost profile.

### 6. A deploy is not a provision — never reprovision to ship an image

**Updating an application image must never replace, recreate, or reprovision the
infrastructure that runs it.** Rolling out a new container version is a *deploy*;
creating the host, role, volume and network is a *provision*. Conflating them is a
defect, not a style preference.

Concretely, for anything that runs a container:

- **The image tag does not belong in Terraform.** Not in a `local`, not in a tfvars,
  not rendered into `user_data`, not in a launch template baked at apply time. Any
  of those makes `terraform apply` the deploy mechanism, and on EC2 with
  `user_data_replace_on_change` it means a tag bump **destroys and rebuilds the
  instance** — taking its local state (staged data, caches, scratch volumes) with it.
- **Put the tag in a mutable, runtime-read location** the workload consults when it
  starts or runs: an S3 pointer/env object, an SSM parameter, or an ECS task
  definition revision. Terraform owns the *pointer*, never the *value*.
- **Fetch it with `aws s3 cp`, never `s3 sync`.** Two git-SHA tags are the same
  length, so a bump does not change the object's size and `sync` skips it — the host
  silently keeps running the old image. This has bitten twice; assume it will again.
- **Ship a deploy script** that publishes the pointer, and say plainly in the module
  README that bumping an image needs no Terraform run.
- **Tags stay immutable and SHA-based** (never `:latest`), so the pointer's value is
  an exact record of what ran.

The failure this prevents is not only the wasted replacement. A tag pinned in
Terraform drifts behind the code it is supposed to run, because bumping it feels
like an infrastructure change and gets deferred — until an operator runbook fails
with something as unhelpful as `No such file or directory`, five commits of missing
application code behind the tag.

Reference implementations: `compute/ec2-app` (bundle `deploy.env`, app tier) and
`compute/ingest-runner` (`image_pointer_uri` + `arag-resolve-image`, batch tier).
Enforced by `tests/unit/test_ingest_image_decoupling.py`.

## AWS credential rule — the agent uses ONLY scoped identities

**Hard rule, no exceptions.** Claude Code reaches AWS **only** as:

| Profile | Identity | Use |
|---|---|---|
| `readonlyagent` | IAM user, read-only allow-list | reads, MCP queries |
| `genai-tf` | `tfuser` → assumes `genai-terraform-exec` | all provisioning |
| `tfuser` | thin user, `sts:AssumeRole` only | the doorway to `genai-tf` |

**The human's admin profile (`<admin-profile>` below; the real name is in the
gitignored `CLAUDE.local.md`) is OFF-LIMITS to the agent — for writes AND for reads.** The agent never runs a command under it, never "just
checks something" with it, and never looks for a workaround.

- **There is no `[default]` profile, deliberately.** It was removed from
  `~/.aws/config` so that an unpinned AWS call fails with `NoCredentials` instead
  of silently running as admin. **Never add one back.** Always pin `AWS_PROFILE`
  (or `--profile`) explicitly.
- **`<admin-profile>` uses `aws login` (browser session), not static keys.** That session
  is for the human's console/admin work. Removing `[default]` means an active
  `<admin-profile>` session can never be picked up ambiently by an unrelated command.
- Console browsing is a **browser** session and is unaffected by any of this.

### When a task needs admin privileges

Some work genuinely requires admin — `global/iam-baseline` (the exec role's
guardrail denies `iam:*User*`), any `aws iam`/account-level write, and the
one-time `scripts/bootstrap-backend.sh`. In those cases the agent must:

1. **State plainly that the step requires admin privileges, and why.**
2. **Hand over the exact command** for the human to run in their own terminal.
3. **WAIT. Do not commit or push anything that depends on the un-applied step.**
   The admin apply is a hard gate on `git commit`, not a caveat in the commit
   body. Leave the work uncommitted, say it is staged and waiting, and only
   commit once the human confirms and `task verify` passes.
4. **Then verify** — re-run post-apply verification and report the real result.

Committing first puts `main` in a state where the tests are red and the commit
message claims an outcome nobody has confirmed. It has happened once: the
exec-role `s3:*` scoping fix was pushed while its apply was outstanding, so the
repo asserted a security property that was not yet true in AWS.

The agent does not run the admin step, and does not plan/dry-run it as `<admin-profile>`.

### Enforcement (not just convention)

`scripts/aws_admin_guard.py` is a `PreToolUse` hook implementing an **allow-list**:
any command that would contact AWS must pin one of the three profiles above.
The admin profile, unknown profiles, and unpinned commands are all blocked. It covers
`Bash`, `PowerShell`, **and** the AWS MCP tool — the MCP server env-pins
`readonlyagent`, so the hook resolves that pin from `.mcp.json` and allows
inherited use, while still blocking a `--profile <admin-profile>` override inside
`cli_command`. Commands that never contact AWS (`fmt`, `hcl fmt`, `validate`,
`task ci`, `aws configure`) need no profile.

It **fails closed**: an unrecognized subcommand, a missing `.mcp.json`, or
unparseable hook input all result in a block.

**Reads go through the MCP server, not the raw `aws` CLI.** `readonlyagent`'s
grants are condition-gated on `aws:CalledViaAWSMCP`, so a raw-CLI read fails with
*"no identity-based policy allows this action"* — which looks like a missing
permission but is really the wrong channel. Misreading that once led to escalating
to the admin profile to "get past" it, so the guard now blocks raw-CLI reads
outright and says why. The raw CLI is only for: writes as `genai-tf` (state-bucket
ops), credential-free subcommands, and `sts get-caller-identity` (the only way to
verify which identity a profile resolves to — MCP can only report its own).

### Safety controls are read-only to the agent

`scripts/protected_paths_guard.py` blocks the agent from editing the guard itself,
its tests, the hook wiring, `.mcp.json`, or `~/.aws/*`. Rationale: the cheapest way
past any guard is to edit the guard, and that looks like ordinary refactoring. It
covers `Edit`/`Write` directly and shell writes best-effort.

**Escape hatch:** the agent cannot change these files *including this guard itself*.
If one genuinely needs fixing, the agent explains the change and the user either
applies it or temporarily removes the second `PreToolUse` entry from
`.claude/settings.json`, then restores it. The agent must not route around it.

All three hooks, including `scripts/shell_tool_guard.py`, are wired in
`.claude/settings.json`, the one committed file under `.claude/`.

Verify the wiring is actually live rather than assuming — attempt an edit to
`scripts/aws_admin_guard.py` and confirm it is refused. `conda run -n py312 pytest
tests/unit/` exercises the scripts, not the wiring.

## Local toolchain (Windows)
- **Terraform and Terragrunt** must be on PATH. Machine-specific install paths go in
  the gitignored `CLAUDE.local.md`.
- **`python` must be on PATH** for the `PreToolUse` guard hooks, which use only the
  standard library. A hook that cannot start does not block anything, so on a machine
  that only has `python3`, add a `python` alias before relying on the guards.
- **Python:** use the `py312` conda environment for all Python build/test
  (`conda run -n py312 ...` or activate it first).
- **task:** go-task is installed (via winget). Equivalents if it is ever missing:
  - `task iam-baseline` → `cd infra/environments/global/iam-baseline && terragrunt apply`
  - `task plan|apply ENV=<env>` → `terragrunt run --all --working-dir infra/environments/<env> -- plan|apply`
  - `task whoami` → `aws sts get-caller-identity`
  The `plan`/`apply`/`iam-baseline` targets self-guard on the resolved STS ARN, so a
  wrong `AWS_PROFILE` is refused rather than silently applied. Direct `terragrunt`
  calls bypass those guards.

## Gates (run before any apply)
`task ci` → ruff + mypy + pytest. `task policy` → checkov. Terraform is
`fmt`/`validate`/`tflint` clean via pre-commit. `.github/workflows/ci.yml` runs the
same gate on a clean checkout, plus checkov and a full-history gitleaks scan, with no
AWS credentials. `tests/unit/` covers the three agent guards, the read-only MCP policy,
image decoupling, bootstrap-script syntax, diagram derivation, the public-safety check
and the public sync; the IaC engine in `src/iac/` has no tests yet.

## Note
This root `CLAUDE.md` is the project guidance (checked in). `.claude/settings.json`
(permissions + the three `PreToolUse` guard hooks) is committed too. Local and
gitignored: the rest of `.claude/`, `CLAUDE.local.md` (machine-specific paths and the
admin profile name), and `.mcp.json` (which pins the AWS MCP server to the
`readonlyagent` profile).
Cross-project conventions (py312, ruff/mypy/pytest gate, secrets discipline, git style)
come from the user-level Claude Code config; this file adds and overrides the
IaC-specific rules.
