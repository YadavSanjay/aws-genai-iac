#!/usr/bin/env python
"""Phase 3 — post-apply DATA steps (Layer C), the per-subsystem ledger.

Terraform provisions the *container* (an empty S3 bucket, a valueless Secrets
Manager secret); these steps put the *content* in. They run AFTER a subsystem's
Phase 2 components apply, as the exec role (``genai-tf``), and they are NOT ordered
by the Terragrunt DAG — this file is their ordered record.

Why a ledger and not ad-hoc commands: so a new environment (staging/prod) can
replay exactly what was done for dev, and so no data step is silently skipped.
Each subsystem contributes its steps here in the SAME change that lands and
verifies the subsystem (its definition-of-done), with a dated note.

── HOW TO USE ──────────────────────────────────────────────────────────────────
    # Print the exact commands for a subsystem, run NOTHING (default):
    python scripts/postdeploy.py --env dev --subsystem raginference
    # Print everything for an env:
    python scripts/postdeploy.py --env staging --subsystem all
    # List the registry:
    python scripts/postdeploy.py --list
    # Actually execute the automated steps (as genai-tf):
    AWS_PROFILE=genai-tf python scripts/postdeploy.py --env dev --subsystem all --run

Default is PRINT-ONLY: it resolves and shows the command a human would run and
touches nothing. ``--run`` executes the automated steps; MANUAL steps are never
executed — they are printed and summarised so they cannot be forgotten.

── STATUS ──────────────────────────────────────────────────────────────────────
The dev data steps below were run during the dev rollout. The registry is
env-parameterised (bucket names are ``genai-<env>-...``), so the same steps target
staging/prod by changing ``--env`` — but the per-subsystem seed inputs (the
RagInference weights on disk, the MacroRAG compose bundle in its sibling checkout)
must be present on the operator's machine when ``--run`` is used.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REGION = "us-east-1"


@dataclass(frozen=True)
class Step:
    """One post-apply data step for a subsystem."""

    id: str
    summary: str
    # Automated step: build the argv to run, given the target env. The command is
    # run with THIS interpreter (sys.executable), so it inherits the py312 env when
    # the dispatcher is invoked via `conda run -n py312 python scripts/postdeploy.py`.
    make_argv: Callable[[str], list[str]] | None = None
    # Manual step (not yet automated): the instruction to print. Never executed.
    manual_note: str | None = None
    # Provenance: when/why the step was added — for the 6-month-later review.
    note: str = ""


def _script(name: str, *args: str) -> list[str]:
    """argv that runs a sibling repo script with the current interpreter."""
    return [sys.executable, str(REPO_ROOT / "scripts" / name), *args]


# ── Per-subsystem step builders ────────────────────────────────────────────────
# Bucket-name templates mirror the Terragrunt `bucket_name` inputs
# (genai-${env}-<component>-${region}); keep them in sync if a component's name
# changes.


def _raginference_steps() -> list[Step]:
    def seed_weights(env: str) -> list[str]:
        bucket = f"genai-{env}-raginference-weights-{REGION}"
        return _script("seed_raginference_weights.py", "--bucket", bucket)

    return [
        Step(
            id="seed-weights",
            summary="Seed BGE-M3 + Jina reranker weights (HF-cache layout) into the bucket.",
            make_argv=seed_weights,
            note=(
                "2026-07, RagInference R2. The bucket is empty until this runs; the Fargate "
                "task syncs it into HF_HOME on every cold start (MODEL_SOURCE=s3, offline). "
                "Idempotent — re-uploads only changed objects and re-pins refs/main. Seeds "
                "from the local HF cache; pass --cache-hub to seed_raginference_weights.py if "
                "it is not at the default path."
            ),
        ),
    ]


def _macrorag_steps() -> list[Step]:
    def deploy_bundle(env: str) -> list[str]:
        bucket = f"genai-{env}-macrorag-corpus-{REGION}"
        return _script("deploy_macrorag_bundle.py", "--bucket", bucket)

    return [
        Step(
            id="deploy-bundle",
            summary="Upload the docker-compose deploy bundle to the corpus deploy/ prefix.",
            make_argv=deploy_bundle,
            note=(
                "2026-07, MacroRAG M5. Reads compose + config from the MacroRAG sibling "
                "checkout (pass --source to deploy_macrorag_bundle.py if it is not adjacent). "
                "The EC2 bootstrap s3-syncs s3://<bucket>/deploy every boot and runs "
                "`docker compose up`."
            ),
        ),
        Step(
            id="app-secret-value",
            summary="Populate the MacroRAG app secret VALUE in Secrets Manager (empty container).",
            manual_note=(
                "MANUAL — not scripted (the value never touches the repo). 10-security/secrets "
                "creates the EMPTY container genai-<env>/macrorag/app; put the value as genai-tf:\n"
                "    aws secretsmanager put-secret-value --profile genai-tf \\\n"
                "      --secret-id genai-<env>/macrorag/app --secret-string file://<local .env>\n"
                "The value is rendered verbatim to the compose env_file on the host. Never commit."
            ),
            note="2026-07, MacroRAG M4/M5.",
        ),
    ]


# ══════════════════════════════════════════════════════════════════════════════
# SUBSYSTEM REGISTRY — append new subsystems / steps here as they are validated.
# ──────────────────────────────────────────────────────────────────────────────
# When a subsystem's provisioning is landed & verified, add (or extend) its entry
# with the exact data step(s) run, a dated `note`, and either a `make_argv` (an
# automated script invocation) or a `manual_note` (an instruction that is printed,
# never executed). Empty list = the subsystem has no data step yet.
# ══════════════════════════════════════════════════════════════════════════════
SUBSYSTEMS: dict[str, list[Step]] = {
    "raginference": _raginference_steps(),
    "macrorag": _macrorag_steps(),
    "arag": [],  # not built yet — add its Layer C steps when validated.
    "quantlibpricer": [],  # not built yet.
}


@dataclass
class Outcome:
    ran: int = 0
    printed: int = 0
    manual: list[str] = field(default_factory=list)


def _emit_step(step: Step, env: str, run: bool, outcome: Outcome) -> None:
    print(f"\n  • [{step.id}] {step.summary}")
    if step.note:
        print(f"      note: {step.note}")

    if step.manual_note is not None:
        print("      MANUAL:")
        for line in step.manual_note.splitlines():
            print(f"        {line.replace('<env>', env)}")
        outcome.manual.append(f"{step.id}")
        return

    assert step.make_argv is not None  # automated step
    argv = step.make_argv(env)
    printable = " ".join(argv)
    if run:
        print(f"      RUN: {printable}")
        subprocess.run(argv, check=True)  # noqa: S603 — argv is built here, not user input
        outcome.ran += 1
    else:
        print(f"      would run: {printable}")
        outcome.printed += 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--env", default="dev", help="Target environment (default: dev).")
    parser.add_argument(
        "--subsystem",
        default="all",
        choices=[*SUBSYSTEMS.keys(), "all"],
        help="Subsystem to run Layer C steps for, or 'all' (default).",
    )
    parser.add_argument(
        "--run",
        action="store_true",
        help="Execute automated steps (default: print only, touch nothing).",
    )
    parser.add_argument("--list", action="store_true", help="List the registry and exit.")
    args = parser.parse_args(argv)

    if args.list:
        for name, steps in SUBSYSTEMS.items():
            print(f"{name}: {len(steps)} step(s)")
            for s in steps:
                kind = "manual" if s.manual_note is not None else "auto"
                print(f"    [{kind}] {s.id} — {s.summary}")
        return 0

    names = list(SUBSYSTEMS) if args.subsystem == "all" else [args.subsystem]
    mode = "RUN" if args.run else "PRINT-ONLY (pass --run to execute)"
    print(f"Phase 3 post-apply data steps — env={args.env}  mode={mode}")

    outcome = Outcome()
    for name in names:
        steps = SUBSYSTEMS[name]
        print(f"\n=== {name} ({len(steps)} step(s)) ===")
        if not steps:
            print("  (no data steps registered yet)")
        for step in steps:
            _emit_step(step, args.env, args.run, outcome)

    print(
        f"\nSummary: {outcome.ran} run, {outcome.printed} previewed, "
        f"{len(outcome.manual)} manual step(s) requiring you"
        + (f": {', '.join(outcome.manual)}" if outcome.manual else "")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
