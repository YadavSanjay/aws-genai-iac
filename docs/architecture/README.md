# Architecture

> **For a narrative tour of what is actually built**, layer by layer with the
> rationale for each choice, see
> [`../guides/infrastructure-walkthrough.md`](../guides/infrastructure-walkthrough.md).
> This file records the decision *log*; that one explains the estate.

- **ADRs** — *convention, not yet started.* No ADR files exist. When adopted: one
  Markdown file per decision (`0001-record-architecture-decisions.md`,
  `0002-single-account-multi-env.md`, …) in the standard ADR format
  (Context / Decision / Consequences). Meanwhile the holistic decision record — with
  full rationale (cost, simplicity, workload fit) — is
  [`../design/design-decisions.md`](../design/design-decisions.md); it and the
  [design docs](../design/README.md) are the first candidates for ADR extraction.
- **Diagrams** — a hand-built overview in [`../images/architecture.svg`](../images/architecture.svg),
  and three views auto-derived from the Terragrunt code in [`../diagrams/`](../diagrams/README.md).

## Key decisions already made

> The terse list below is a summary; the full rationale and current status of each
> live in [`../design/design-decisions.md`](../design/design-decisions.md) and
> [`../design/aws-service-consolidation.md`](../design/aws-service-consolidation.md).

- **IaC:** Terraform + **Terragrunt** for DRY multi-component state.
- **Accounts:** single AWS account, logical `dev`/`staging`/`prod` isolation.
- **State:** one S3 bucket (`aws-genai-iac-tfstate`, versioned, SSE-KMS `aws/s3`,
  `us-east-1`), one key per component, **S3-native locking** (`use_lockfile`) — no
  DynamoDB lock table. Root Terragrunt config is `infra/root.hcl` (a *root* file
  named `terragrunt.hcl` is a deprecated anti-pattern).
- **Terraform identity:** all runs assume `genai-terraform-exec`; admin credentials
  are never used by automation or by the coding agent. See
  `../runbooks/terraform-execution-role.md`.
- **UI:** FastAPI backend + React frontend over a shared UI-agnostic engine.
