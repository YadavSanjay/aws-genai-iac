#!/usr/bin/env python3
"""Upload the XbrlRag APP-TIER deploy bundle to the filings bucket's deploy/ prefix.

Scope is the app-tier compose stack (ui + api + mcp), so it carries the two images
that stack runs: arag (api + mcp) and arag-ui. The arag-ingest image is NOT here —
it belongs to the on-demand ingest runner (A7), which is not a compose service and
has its own lifecycle; this script never pushes it.

The bundle is the AWS docker compose file plus any config files it mounts by
relative path. The EC2 bootstrap `aws s3 sync`s s3://<bucket>/deploy ->
/opt/app/bundle every boot and runs `docker compose -f <compose_file_relpath>
up`, so the bundle MUST preserve the repo-relative layout for compose's mounts to
resolve.

The compose + config live in the XbrlRag repo (a sibling checkout), not here, so
this reads them from --source. Only the listed files are uploaded — never the
whole infra/ tree. Add config files the compose mounts with --extra-file (they
upload under the same repo-relative path).

Objects land KMS-encrypted via the bucket's default encryption (no SSE header is
sent — the bucket policy's Null guard permits headerless, default-encrypted puts).

Run (writes go as the exec role):
    AWS_PROFILE=genai-tf python scripts/deploy_arag_bundle.py --tag arm64-abc1234
    # explicit source / dry run:
    AWS_PROFILE=genai-tf python scripts/deploy_arag_bundle.py \
        --source ../XbrlRag --tag arm64-abc1234 --dry-run
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# The compose file, as a repo-relative path preserved under the deploy/ prefix.
# It must match the component's compose_file_relpath. Config files the compose
# mounts are added at runtime via --extra-file (also repo-relative).
COMPOSE_RELPATH = "infra/docker/docker-compose.aws.yml"
DEPLOY_PREFIX = "deploy"
DEPLOY_ENV_KEY = f"{DEPLOY_PREFIX}/deploy.env"

# Placeholder tag in the committed deploy.env, filled by --tag when given.
TAG_SENTINEL = "arm64-SETME"


def _default_source() -> Path:
    # XbrlRag is a sibling checkout of aws-genai-iac by default.
    return (Path(__file__).resolve().parents[2] / "XbrlRag").resolve()


def _default_deploy_env() -> Path:
    # The committed deploy.env template lives with its component (this repo).
    return Path(__file__).resolve().parents[1] / "infra/environments/dev/42-arag/app/deploy.env"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bucket",
        default="genai-dev-arag-filings-us-east-1",
        help="Filings bucket holding the deploy/ prefix (default: %(default)s).",
    )
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--profile", default=None, help="AWS profile (else the ambient chain).")
    parser.add_argument(
        "--source",
        type=Path,
        default=_default_source(),
        help="XbrlRag repo root holding infra/ (default: sibling ../XbrlRag).",
    )
    parser.add_argument(
        "--deploy-env",
        type=Path,
        default=_default_deploy_env(),
        help="Committed deploy.env template with ${REGISTRY} placeholder.",
    )
    parser.add_argument(
        "--tag",
        default=None,
        help=f"Image tag to fill in for {TAG_SENTINEL} in deploy.env (e.g. arm64-abc1234). "
        "Omit to upload the tags exactly as written in the file.",
    )
    parser.add_argument(
        "--extra-file",
        action="append",
        default=[],
        metavar="RELPATH",
        help="Repo-relative config file the compose mounts; repeatable.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="List what would upload, touch nothing."
    )
    args = parser.parse_args()

    source: Path = args.source.resolve()
    bundle_files = [COMPOSE_RELPATH, *args.extra_file]
    missing = [f for f in bundle_files if not (source / f).is_file()]
    if missing:
        print(f"ERROR: source {source} is missing bundle files: {missing}", file=sys.stderr)
        print("Point --source at the XbrlRag repo root (the dir holding infra/).", file=sys.stderr)
        print(
            f"NOTE: {COMPOSE_RELPATH} is the AWS-mode compose file; create it if absent.",
            file=sys.stderr,
        )
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

    for rel in bundle_files:
        local = source / rel
        key = f"{DEPLOY_PREFIX}/{rel}"
        size = local.stat().st_size
        if args.dry_run:
            print(f"  [DRY RUN] {rel}  ({size} bytes) -> s3://{args.bucket}/{key}")
            continue
        assert client is not None
        client.upload_file(str(local), args.bucket, key)
        print(f"  uploaded {rel}  ({size} bytes) -> s3://{args.bucket}/{key}")

    # Render + upload deploy.env: fill ${REGISTRY} always, and the tag sentinel
    # when --tag is given.
    rendered = deploy_env_template.read_text(encoding="utf-8").replace("${REGISTRY}", registry)
    if args.tag:
        rendered = rendered.replace(TAG_SENTINEL, args.tag)
    tags = [ln for ln in rendered.splitlines() if ln and not ln.startswith("#")]
    if TAG_SENTINEL in rendered:
        print(
            f"WARNING: {TAG_SENTINEL} is still present in deploy.env — pass --tag or edit the "
            "file, or the host will try to pull a non-existent image.",
            file=sys.stderr,
        )
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
