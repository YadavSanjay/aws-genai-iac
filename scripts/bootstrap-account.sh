#!/usr/bin/env bash
#
# Phase 0 — ACCOUNT BOOTSTRAP (run by an ADMIN, once per AWS account).
#
# The ordered, idempotent ledger of the admin-only steps that must happen before
# ANY Terragrunt run, because the exec role cannot create these for itself:
#
#   1. the S3 Terraform state backend  (chicken-and-egg: state must exist first)
#   2. global/iam-baseline             (genai-terraform-exec + tfuser + boundary)
#
# See docs/runbooks/provision-env.md (Phase 0) for the rationale and the identity
# model, and docs/runbooks/terraform-execution-role.md for the deep detail.
#
# ── HOW TO USE ────────────────────────────────────────────────────────────────
#   Preview (default — prints/plan-only, changes NOTHING):
#       scripts/bootstrap-account.sh
#   Execute (actually create the backend + apply the baseline):
#       scripts/bootstrap-account.sh --apply
#
#   Config via env (defaults match infra/account.hcl):
#       AWS_REGION=us-east-1  STATE_BUCKET=aws-genai-iac-tfstate
#       ADMIN_PROFILE=<name>          # optional: pin an admin profile; else ambient chain
#
# ── IDENTITY ──────────────────────────────────────────────────────────────────
#   Run this as your ADMIN identity — NOT genai-tf (the exec role cannot create
#   itself; global/iam-baseline's guardrail denies iam:*User*). This script
#   refuses to proceed if it detects the exec role or readonlyagent.
#
#   NOTE: the aws_admin_guard.py PreToolUse hook blocks the AGENT from running
#   admin AWS commands. This script is for a HUMAN operator to run in their own
#   terminal during a real account bootstrap. Nothing here is run by the agent.
#
# ── STATUS ────────────────────────────────────────────────────────────────────
#   The dev account is ALREADY bootstrapped (backend + iam-baseline applied,
#   reconciled 2026-07-22). This script exists to (a) document exactly what was
#   run, and (b) reproduce it verbatim when a new account (or a fresh re-bootstrap)
#   is needed. It is idempotent, so re-running against the dev account is safe.
#
set -euo pipefail

# --- Config -------------------------------------------------------------------
REGION="${AWS_REGION:-us-east-1}"
BUCKET="${STATE_BUCKET:-aws-genai-iac-tfstate}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg (see --help)" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS=(aws)
[[ -n "${ADMIN_PROFILE:-}" ]] && AWS=(aws --profile "${ADMIN_PROFILE}")

say()  { printf '\n>> %s\n' "$*"; }
step() { printf '\n── STEP %s ─────────────────────────────────────────────\n' "$*"; }

if [[ "${APPLY}" -eq 1 ]]; then
  say "MODE: --apply  (this WILL create/modify AWS resources)"
else
  say "MODE: preview  (nothing is changed; pass --apply to execute)"
fi
say "region=${REGION}  state_bucket=${BUCKET}  admin_profile=${ADMIN_PROFILE:-<ambient>}"

# --- Preflight: must be an ADMIN identity, never the exec role ----------------
step "0  preflight — identity check"
CALLER_ARN="$("${AWS[@]}" sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
if [[ -z "${CALLER_ARN}" ]]; then
  echo "No AWS identity resolved. Authenticate as your admin identity first" >&2
  echo "(or set ADMIN_PROFILE=<name>), then re-run." >&2
  exit 1
fi
case "${CALLER_ARN}" in
  *:assumed-role/genai-terraform-exec/*)
    echo "REFUSING: you are the exec role. Phase 0 must run as ADMIN — the role" >&2
    echo "cannot create itself. Unset AWS_PROFILE=genai-tf / use your admin identity." >&2
    exit 1 ;;
  *:user/readonlyagent)
    echo "REFUSING: readonlyagent is read-only. Use your admin identity." >&2
    exit 1 ;;
esac
echo "caller: ${CALLER_ARN}"

# --- STEP 1: Terraform state backend (create-if-not-exists) -------------------
# The exec role intentionally lacks s3:CreateBucket / PutBucket*, so this is an
# admin step. scripts/bootstrap-backend.sh does the actual creation (bucket +
# versioning + SSE-KMS + public-access-block); we call it ONLY when the bucket is
# absent, which makes the whole thing idempotent (the raw script errors on an
# existing bucket). Locking is S3-native (use_lockfile in infra/root.hcl) — no
# DynamoDB table.
step "1  Terraform state backend  (S3: ${BUCKET})"
if "${AWS[@]}" s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "state bucket ${BUCKET} already exists — skipping creation (idempotent)."
else
  if [[ "${APPLY}" -eq 1 ]]; then
    echo "creating state bucket via scripts/bootstrap-backend.sh ..."
    AWS_REGION="${REGION}" STATE_BUCKET="${BUCKET}" \
      ${ADMIN_PROFILE:+AWS_PROFILE="${ADMIN_PROFILE}"} \
      "${REPO_ROOT}/scripts/bootstrap-backend.sh"
  else
    echo "[preview] would run: AWS_REGION=${REGION} STATE_BUCKET=${BUCKET} scripts/bootstrap-backend.sh"
  fi
fi

# --- STEP 2: global/iam-baseline ---------------------------------------------
# Creates genai-terraform-exec, its scoped policies, the genai-app-boundary, and
# tfuser. Idempotent (terragrunt apply). Preview runs a plan; --apply applies.
# This component has NO assume_role provider block (the role does not exist yet),
# so it MUST run as the admin.
step "2  global/iam-baseline  (exec role + tfuser + boundary)"
IAM_DIR="${REPO_ROOT}/infra/environments/global/iam-baseline"
if [[ "${APPLY}" -eq 1 ]]; then
  echo "applying iam-baseline ..."
  ( cd "${IAM_DIR}" && terragrunt apply )
else
  echo "[preview] running a plan (no changes) ..."
  ( cd "${IAM_DIR}" && terragrunt plan ) || \
    echo "[preview] plan failed — expected if the state backend does not exist yet (STEP 1)."
fi

# ══════════════════════════════════════════════════════════════════════════════
# APPEND FUTURE PHASE 0 ADMIN STEPS BELOW
# ──────────────────────────────────────────────────────────────────────────────
# Only steps that (a) require admin (the exec role's guardrail denies them) AND
# (b) are account-global (run once per account, shared by every environment and
# subsystem) belong here. Per-environment work is Phase 2 (task apply); per-
# subsystem data loads are Phase 3 (scripts/postdeploy.py). Most new work is NOT
# a Phase 0 step.
#
# Convention for each addition (keep it a self-explanatory ledger):
#   step "N  <what>  (<why it must be admin + account-global>)"
#   # <date> — added with <milestone/subsystem>. <what was actually run>.
#   if [[ "${APPLY}" -eq 1 ]]; then <command>; else echo "[preview] would run: <command>"; fi
# ══════════════════════════════════════════════════════════════════════════════

# --- Done ---------------------------------------------------------------------
step "done"
cat <<EOF
Phase 0 ${APPLY:+}$([[ "${APPLY}" -eq 1 ]] && echo "APPLIED" || echo "PREVIEWED").

Next:
  * Configure the genai-tf profile (tfuser -> genai-terraform-exec) if not already —
    see docs/runbooks/terraform-execution-role.md (Steady state).
  * Phase 1+ run as the EXEC role:  AWS_PROFILE=genai-tf
      terragrunt apply --working-dir infra/environments/global/cost-guardrails   # Phase 1
      task apply ENV=<env>                                                        # Phase 2
      python scripts/postdeploy.py --env <env> --subsystem all                   # Phase 3
      task verify ENV=<env>                                                       # Phase 4

Admin-apply-before-commit: do NOT commit/push work that depends on an un-applied
Phase 0 step until it is applied and verification passes.
EOF
