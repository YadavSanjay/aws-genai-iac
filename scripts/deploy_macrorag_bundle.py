#!/usr/bin/env python3
"""Upload the MacroRAG deploy bundle to the corpus bucket's deploy/ prefix.

The bundle is the docker compose file plus the two config files it mounts by
relative path (rag.aws.yaml, otel-collector-config.yaml). The EC2 bootstrap
`aws s3 sync`s s3://<bucket>/deploy -> /opt/app/bundle every boot and runs
`docker compose -f infra/docker/docker-compose.aws.yml up`, so the bundle MUST
preserve the infra/ layout for compose's ../config and ../otel mounts to resolve.

The compose + config live in the MacroRAG repo (a sibling checkout), not here, so
this reads them from --source. Only these three files are uploaded — never the
whole infra/ tree (helm/, ci/, etc. are irrelevant to the single-EC2 target).

Objects land KMS-encrypted via the bucket's default encryption (no SSE header is
sent — the bucket policy's Null guard permits headerless, default-encrypted puts).

Run (writes go as the exec role):
    AWS_PROFILE=genai-tf python scripts/deploy_macrorag_bundle.py
    # explicit source / dry run:
    AWS_PROFILE=genai-tf python scripts/deploy_macrorag_bundle.py \
        --source ../MacroRAG --dry-run
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Files to upload, as repo-relative paths preserved under the deploy/ prefix.
BUNDLE_FILES = (
    "infra/docker/docker-compose.aws.yml",
    "infra/config/rag.aws.yaml",
    "infra/otel/otel-collector-config.yaml",
)
DEPLOY_PREFIX = "deploy"
# The per-deploy image-tag env-file. Its ${REGISTRY} placeholder is filled from
# STS at upload time, so the committed template carries no real account id.
DEPLOY_ENV_KEY = f"{DEPLOY_PREFIX}/deploy.env"


def _default_source() -> Path:
    # MacroRAG is a sibling checkout of aws-genai-iac by default.
    return (Path(__file__).resolve().parents[2] / "MacroRAG").resolve()


def _default_deploy_env() -> Path:
    # The committed deploy.env template lives with its component (this repo).
    return Path(__file__).resolve().parents[1] / "infra/environments/dev/41-macrorag/app/deploy.env"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bucket",
        default="genai-dev-macrorag-corpus-us-east-1",
        help="Corpus bucket (default: genai-dev-macrorag-corpus-us-east-1).",
    )
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--profile", default=None, help="AWS profile (else the ambient chain).")
    parser.add_argument(
        "--source",
        type=Path,
        default=_default_source(),
        help="MacroRAG repo root holding infra/ (default: sibling ../MacroRAG).",
    )
    parser.add_argument(
        "--deploy-env",
        type=Path,
        default=_default_deploy_env(),
        help="Committed deploy.env template with ${REGISTRY} placeholder.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="List what would upload, touch nothing."
    )
    args = parser.parse_args()

    source: Path = args.source.resolve()
    missing = [f for f in BUNDLE_FILES if not (source / f).is_file()]
    if missing:
        print(f"ERROR: source {source} is missing bundle files: {missing}", file=sys.stderr)
        print("Point --source at the MacroRAG repo root (the dir holding infra/).", file=sys.stderr)
        return 2
    deploy_env_template: Path = args.deploy_env.resolve()
    if not deploy_env_template.is_file():
        print(f"ERROR: deploy.env template not found: {deploy_env_template}", file=sys.stderr)
        return 2

    print(f"Bundle source: {source}")
    print(f"Target: s3://{args.bucket}/{DEPLOY_PREFIX}/  (profile={args.profile})")

    client = None
    registry = "<registry>"  # dry-run placeholder; resolved from STS on a real run
    if not args.dry_run:
        import boto3

        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("s3")
        account = session.client("sts").get_caller_identity()["Account"]
        registry = f"{account}.dkr.ecr.{args.region}.amazonaws.com"

    for rel in BUNDLE_FILES:
        local = source / rel
        key = f"{DEPLOY_PREFIX}/{rel}"
        size = local.stat().st_size
        if args.dry_run:
            print(f"  [DRY RUN] {rel}  ({size} bytes) -> s3://{args.bucket}/{key}")
            continue
        assert client is not None
        client.upload_file(str(local), args.bucket, key)
        print(f"  uploaded {rel}  ({size} bytes) -> s3://{args.bucket}/{key}")

    # Render + upload deploy.env (image tags), with ${REGISTRY} filled in.
    rendered = deploy_env_template.read_text(encoding="utf-8").replace("${REGISTRY}", registry)
    tags = [ln for ln in rendered.splitlines() if ln and not ln.startswith("#")]
    if args.dry_run:
        print(f"  [DRY RUN] deploy.env -> s3://{args.bucket}/{DEPLOY_ENV_KEY}")
        for ln in tags:
            print(f"             {ln}")
    else:
        assert client is not None
        client.put_object(Bucket=args.bucket, Key=DEPLOY_ENV_KEY, Body=rendered.encode("utf-8"))
        print(f"  uploaded deploy.env ({len(tags)} tags) -> s3://{args.bucket}/{DEPLOY_ENV_KEY}")

    print("Done." if not args.dry_run else "Dry run complete; nothing uploaded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
