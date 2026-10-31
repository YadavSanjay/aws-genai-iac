<h1 align="center">aws-genai-iac</h1>

<p align="center">
  <b>Terraform and Terragrunt for running GenAI apps on AWS.</b><br>
  Infrastructure for a small dev estate: three RAG and analytics applications, shared embedding and
  vector services, and the data, security and networking under them. Services are tested against
  the live AWS API after each apply, and a coding agent works on it with scoped identities only.
</p>

<p align="center">
  <img alt="Terraform 1.15" src="https://img.shields.io/badge/Terraform-1.15-7B42BC?logo=terraform&logoColor=white">
  <img alt="Terragrunt 1.1" src="https://img.shields.io/badge/Terragrunt-1.1-5C4EE5">
  <img alt="AWS" src="https://img.shields.io/badge/cloud-AWS-232F3E">
  <img alt="Python 3.12" src="https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white">
  <img alt="checkov: 0 failed" src="https://img.shields.io/badge/checkov-0%20failed-2ea043">
  <img alt="arm64 first" src="https://img.shields.io/badge/compute-arm64%20first-0f766e">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>

> **Where this stands.** The `dev` infrastructure is fully applied and currently **parked** to save
> money, so nothing is serving right now. The Python control plane on top of it is **about 5–10%
> built**: the infrastructure is the mature part of this repo, not the CLI or the dashboard.
> [Current status](docs/status.md) has the full picture.

---

## Why this exists

A GenAI app is cheap to demo and easy to leave expensive or exposed. A successful `apply` only means
Terraform got a 200, so this repo follows a few extra rules:

- **Apply success isn't verification.** After each apply, tests query the live AWS API and assert on
  what was really created: encryption on, public access blocked, policies as intended. Negative
  tests confirm that what should be denied is denied.
- **One service per change.** Module, tests, gate, plan, apply, verify, commit. A plan that touches
  anything outside the service under construction means the change is too big.
- **Security rules are backed by checks.** Policy-as-code, module validation and tests make a rule
  hard to drop quietly. A deliberate relaxation is written down with its reason and compensating
  control.
- **Cost is a design constraint.** Scheduled NAT instance rather than NAT Gateway, Graviton, a free
  S3 gateway endpoint, no load balancer in `dev`, and scale-to-zero. One flag parks the whole estate
  and takes it from about $4 a day to about $0.68.
- **A deploy is not a provision.** Shipping a new image never touches Terraform. Hosts read a mutable
  pointer at start-up, so an image bump can't destroy an instance or its local state.
- **A coding agent can work here safely.** Hooks block the admin profile outright, and the agent
  can't edit those hooks. It holds scoped identities only, and it can't push.

## Questions it answers

| You want to know… | This repo shows you… |
|---|---|
| How do I run several RAG apps on AWS without paying for each one's GPU and vector store? | One RagInference service and one Qdrant store, shared over private DNS |
| How little can this cost when nobody is using it? | Daily windows, a park flag, and an [idle-cost table](docs/runbooks/day2-operations.md#10-what-costs-money-while-idle) for each line item |
| How do I reach private services with no public ingress? | SSM port-forwarding, with no SSH and no load balancer |
| How do I let a coding agent run Terraform without giving it the keys? | An exec role behind a permissions boundary, plus [enforced guard hooks](#harness-engineering) |
| Is what's deployed what the code says? | 29 live-AWS test modules, run after each apply |
| How do I ship an image without touching infrastructure? | [Deploy decoupling](docs/runbooks/day2-operations.md#5-ship-an-app-image-a-deploy-never-a-provision): a runtime-read pointer and a deploy script |

---

## Architecture at a glance

Each change takes the same path to AWS, and the estate builds up in layers. Applications sit on
shared services, which sit on data, security and networking:

<p align="center">
  <a href="docs/images/architecture.svg">
    <img src="docs/images/architecture.svg" width="100%"
         alt="How aws-genai-iac works. A change passes agent guards, then gates (ruff, mypy, pytest, checkov and gitleaks), then a plan that is read before apply under an exec role with a permissions boundary, then verification against live AWS. It provisions one AWS account with no public ingress: operators reach private hosts through SSM port-forwarding. Three application tiers (MacroRAG, XbrlRag with RDS Postgres, and Faultline) and an ingest runner call shared services: RagInference on ECS Fargate and a Qdrant vector store, found through Cloud Map private DNS. Below them sit data and security (S3, ECR, a KMS customer-managed key and Secrets Manager) and networking (a VPC, an S3 gateway endpoint, a scheduled NAT instance and security groups). Alongside, EventBridge daily windows, a single park-mode flag, scheduler alarms and cost guardrails control spend and detect failed schedules.">
  </a>
</p>

- **Modules hold the logic.** 21 Terraform modules live in `infra/modules/`. Thin Terragrunt
  composition in `infra/environments/` wires them into 28 components, with one state key each and
  S3-native locking.
- **One account, logical environments.** `dev`, `staging` and `prod` are designed to separate by name
  prefix, tags and VPC. Only `dev` and `global` exist today.
- **Diagrams can't drift.** Three AWS-icon views (dependencies, security, data flow) are
  [derived from the Terragrunt code](docs/diagrams/README.md), offline.

## What runs on it

The applications live in their own repositories. This repo provisions and operates them.

| Application | What it is | How it runs here |
|---|---|---|
| **MacroRAG** | RAG over macroeconomic research | Compose stack on EC2, S3 corpus, CMK data volume |
| **XbrlRag** | Cited, audited numbers from SEC filings | Compose on EC2, RDS Postgres 16, on-demand ingest runner |
| **Faultline** | Portfolio stress testing that calls both RAG apps | Compose on EC2 `t4g.large`, S3 data, app-to-app calls over private DNS |
| **RagInference** *(shared)* | Embedding and reranking | ECS Fargate on arm64, scales to zero |
| **Qdrant** *(shared)* | Vector store | Dedicated `t4g.small`, TLS, CMK data volume |

> **Naming.** Faultline was formerly **QuantLibPricer** and XbrlRag was formerly **ARag**. Their
> infrastructure identifiers keep the old names on purpose (`40-quantlibpricer/`, `42-arag/`, and the
> `qlp-*` and `arag-*` resources), because state keys derive from those paths and renaming would
> replace live infrastructure.

---

## How it's verified

| Layer | What runs | Result |
|---|---|---|
| Unit tests | Guards, read-only MCP policy, diagram derivation, image decoupling, scripts | 176 tests, in CI |
| Live AWS | Post-apply tests against real resources, including negative tests | 29 modules, 291 tests, run by hand after an apply |
| Policy as code | checkov over the real modules | 578 passed, 0 failed, 39 skipped with reasons |
| Terraform | `fmt` in CI; `validate` and `tflint` in pre-commit; five native test files | Clean |
| Secrets | gitleaks over full history, plus a custom scan for account ids, resource ids and machine paths | In CI; the custom scan also runs in pre-commit |
| Types and lint | ruff and strict mypy | Clean |

**What these results don't cover:**

- **The live tests don't run in CI,** because CI holds no AWS credentials. A skipped live test counts
  as *unverified*, never as passing.
- **checkov reports one parsing error.** Its HCL parser rejects a multi-line ternary in
  `data/rds/outputs.tf`. That file holds outputs only, so no resource goes unchecked.
- **Known gaps.** Terraform and provider versions are floors rather than exact pins, the lockfile
  isn't committed, and mandatory tags aren't fully applied or checked yet. `CLAUDE.md` records
  these as targets, not current state.

## Built for audit and governance

The controls a security reviewer asks about are in the code, not left to good intentions.

### Identity and least privilege

- **All provisioning runs as an exec role behind a permissions boundary.** Roles it creates carry
  the same boundary, and explicit denies stop it changing itself, its boundary or the state bucket.
  [Execution role runbook](docs/runbooks/terraform-execution-role.md).
- **Reads run as a separate read-only identity,** gated so its grants only work through the AWS MCP
  server, with explicit denies on image and object contents.
- **There's deliberately no `[default]` AWS profile.** An unpinned command fails instead of quietly
  running with whatever credentials are around.

### Secure defaults

- **Encrypted at rest and in transit.** Customer-managed KMS key for data stores, and TLS enforced
  on S3 and RDS.
- **No public exposure.** Private subnets, no public ingress, and SSM instead of SSH.
- **No secrets in code or state.** They live in Secrets Manager and SSM, fetched at runtime.
- **Audited relaxations.** Where `dev` deliberately gives something up, such as Qdrant auth for now,
  the [status page](docs/status.md#outstanding-work-paused-2026-07-29) and the module README say so.

### Cost tracking and controls

- **A budget and anomaly detection exist at account level,** and the project rule is that each
  non-trivial change states its estimated monthly cost delta.
- **Scheduled by default.** When unparked, tiers run in a daily window and scale to nothing outside it.
- **Silent failures are alarmed.** A failed scheduled start or stop publishes to SNS, because a stop
  that fails quietly is a bill you find out about later.

Detail: [design decisions](docs/design/design-decisions.md) ·
[security walkthrough](docs/guides/infra-walkthrough-security.md) ·
[park mode](docs/design/park-mode.md).

### AI-assisted development lifecycle

This repo is developed with AI coding agents (Claude Code), so the process is built to keep their
changes honest:

- **Plans get read, not skimmed.** Any `destroy` or `replace` stops the work and goes to a human.
- **Admin steps stop at a human.** The agent states why admin is needed, hands over the exact command,
  and commits nothing that depends on it until the human has run it and verification passes.
- **Humans hold the keys.** The agent's GitHub token is read-only, and only the human pushes.

### Harness engineering

The Claude Code harness around the repo is engineered and tested like the product:

- **Three deterministic hooks** ([`scripts/`](scripts/), wired in
  [`.claude/settings.json`](.claude/settings.json)):
  - `aws_admin_guard.py` is an allow-list of scoped AWS identities that fails closed, across shell
    commands and the MCP server.
  - `protected_paths_guard.py` stops the agent editing the guards themselves, their tests, the hook
    wiring or `~/.aws/*`, because the cheapest way past a guard is to edit the guard.
  - `shell_tool_guard.py` sends each command to the shell that can really run it.
- **Guards have tests.** Each one has its own unit suite, including commands that must stay blocked.
- **Public by construction.** `scripts/check_public_safe.py` rejects real identifiers in any tracked
  file, in pre-commit and CI.

Detail: [agent toolkit setup](docs/runbooks/agent-toolkit-setup.md) · [CLAUDE.md](CLAUDE.md).

---

## Quick start

Everything here runs offline. It needs no AWS account and creates nothing.

```bash
git clone <this-repo-url>
cd aws-genai-iac
pip install -e ".[dev,ui,diagrams]"    # Python 3.12

ruff check src tests scripts
mypy
pytest
python scripts/check_public_safe.py
```

These are the commands CI runs. With a `py312` conda env and [go-task](https://taskfile.dev),
`task ci` runs the same gate and also needs [Terraform](https://developer.hashicorp.com/terraform/install)
1.15 for its format check. `task policy` runs checkov through [uv](https://docs.astral.sh/uv/).
Regenerating the diagrams needs Graphviz:

```bash
python scripts/gen_diagrams.py --env dev --view all
```

**To provision this in your own account,** follow the
[provisioning runbook](docs/runbooks/provision-env.md) and start with
[the names a fork must change](docs/runbooks/provision-env.md#forking-names-that-must-change). You'll
also need [Terragrunt](https://terragrunt.gruntwork.io/) 1.1. Real resources cost real money, and the
application images come from each application's own repository.

**The `iac` CLI is a scaffold.** Most of its commands print "not yet implemented"; `task` and
`terragrunt` are the working interface today.
[Design decisions §8](docs/design/design-decisions.md#8-control-plane-software--intended-vs-built-stated-honestly)
explains the sequencing.

## Explore further

| If you want to… | Start here |
|---|---|
| Understand the estate, layer by layer | [Infrastructure walkthrough](docs/guides/infrastructure-walkthrough.md) |
| See what's built and what's open | [Current status](docs/status.md) |
| Know why it's built this way | [Design decisions](docs/design/design-decisions.md) · [design docs](docs/design/README.md) |
| Operate it day to day | [Day-2 runbook](docs/runbooks/day2-operations.md) · [all runbooks](docs/runbooks/README.md) |
| Stand it up from scratch | [Provisioning runbook](docs/runbooks/provision-env.md) |
| Connect a new app to the shared services | [Consuming shared services](docs/guides/consuming-shared-services.md) |
| See every component and edge | [Auto-derived diagrams](docs/diagrams/README.md) |
| Work in the code with Claude Code | [CLAUDE.md](CLAUDE.md) |

<details>
<summary><b>Repository layout</b></summary>

```
infra/modules/        reusable Terraform modules, each with a README on security and cost
infra/environments/   thin Terragrunt composition: dev/ and global/ applied; staging/ and prod/ empty
infra/root.hcl        root Terragrunt config: remote state and provider
policies/             checkov config and the least-privilege MCP IAM policy
scripts/              agent guards, public-safety check, bootstrap, deploy and diagram scripts
tests/unit/           guards, policy, derivation and script tests (no AWS)
tests/integration/    post-apply verification against live AWS
src/iac/              Python engine and CLI (scaffold; the diagram derivation is real)
ui/                   FastAPI health endpoint and a frontend scaffold (pre-alpha)
config/               environment config, no secrets
docs/                 guides/ (walkthrough) · design/ (why) · runbooks/ (how) · diagrams/
```

</details>

---

## License and support

MIT — see [`LICENSE`](LICENSE). The applications this repo deploys live in their own repositories and
carry their own licenses.

**Cost and responsibility.** Provisioning these modules creates billable AWS resources in your
account, and the figures here describe the maintainer's estate, not a quote for yours. Review every
plan before applying it.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

This is a personal project, shared as-is: no support, no stability guarantees, and no promise to
review issues or pull requests.
