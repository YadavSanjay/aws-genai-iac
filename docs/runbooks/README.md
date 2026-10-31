# Runbooks

Operator procedures — one file per scenario.

**Available:**

- `agent-toolkit-setup.md` — connect Claude Code to this account **read-only** via
  the Agent Toolkit for AWS (managed AWS MCP Server) for live troubleshooting.
- `terraform-execution-role.md` — the `genai-terraform-exec` identity model:
  admin bootstraps the backend, all Terraform runs as the exec role, KMS caveat.
  Also covers first-time backend setup (`scripts/bootstrap-backend.sh`) and the
  backend conventions (`root.hcl`, S3-native locking, state-key normalization).
- `provision-env.md` — standing up an environment (new account or new env in the
  existing account) from scratch: the four-phase, identity-gated sequence (account
  bootstrap → global baseline → environment DAG → per-subsystem data steps →
  verify), with a worked RagInference-on-staging example.
- `day2-operations.md` — **running what is already provisioned**: profiles, finding
  hosts by tag, start/stop (incl. the ECS scalable-target gotcha), SSM shells and
  port-forwards with the port map, shipping an app image, debugging a tier that will
  not serve, `dbq.py` against RDS vs local, and a failure-signature table. Keep it
  updated as commands change.
- `arag-db-bootstrap.md` — one-time load of the XbrlRag `xbrl_db` schema into private
  RDS from a laptop over an SSM tunnel (the RDS/pgcrypto and `postgres`-role traps).

**Planned:**

- `drift-remediation.md` — detecting and resolving Terraform drift.
- `incident-response.md` — triage using the monitoring dashboard.
- `cost-review.md` — periodic spend review workflow.
