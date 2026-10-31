#!/usr/bin/env python3
"""Publish the XbrlRag INGEST-RUNNER image pointer to the filings bucket.

The ingest runner resolves its image at run time from a single S3 object rather
than from a tag baked into user_data. That is the whole point of this script:
the instance carries `user_data_replace_on_change`, so a tag in user_data means
every image bump REPLACES the box (and, being a Terraform value, it drifts behind
the code it is supposed to run). Publishing a pointer instead makes a bump a
one-object write with no Terraform run and no reprovision.

Deliberately separate from deploy_arag_bundle.py, which serves the APP tier. The
two tiers run different images on different cadences, and folding them together
would mean an app-tier redeploy could silently move the ingest image too. The
shared part is ~15 lines of boto3 setup, which is not worth coupling them over.

Objects land KMS-encrypted via the bucket's default encryption (no SSE header is
sent — the bucket policy's Null guard permits headerless, default-encrypted puts).

Run (writes go as the exec role):
    AWS_PROFILE=genai-tf python scripts/deploy_arag_ingest_image.py --tag arm64-abc1234
    # inspect without writing:
    AWS_PROFILE=genai-tf python scripts/deploy_arag_ingest_image.py --tag arm64-abc1234 --dry-run
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# Must match image_pointer_key in infra/environments/dev/42-arag/ingest/terragrunt.hcl.
POINTER_KEY = "deploy/ingest.env"

# Placeholder tag in the committed template, filled by --tag when given.
TAG_SENTINEL = "arm64-SETME"

# The env var the runner's arag-resolve-image sources out of the object.
IMAGE_VAR = "ARAG_INGEST_IMAGE"


def _default_template() -> Path:
    return Path(__file__).resolve().parents[1] / "infra/environments/dev/42-arag/ingest/deploy.env"


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
        "--template",
        type=Path,
        default=_default_template(),
        help="Committed deploy.env template with the ${REGISTRY} placeholder.",
    )
    parser.add_argument(
        "--tag",
        default=None,
        help=f"Image tag to fill in for {TAG_SENTINEL} (e.g. arm64-abc1234). "
        "Omit to publish the tag exactly as written in the template.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Print what would be published, write nothing."
    )
    args = parser.parse_args()

    template: Path = args.template.resolve()
    if not template.is_file():
        print(f"ERROR: pointer template not found: {template}", file=sys.stderr)
        return 2

    registry = "<registry>"  # dry-run placeholder; resolved from STS on a real run
    client = None
    if not args.dry_run:
        import boto3

        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("s3")
        account = session.client("sts").get_caller_identity()["Account"]
        registry = f"{account}.dkr.ecr.{args.region}.amazonaws.com"

    rendered = template.read_text(encoding="utf-8").replace("${REGISTRY}", registry)
    if args.tag:
        rendered = rendered.replace(TAG_SENTINEL, args.tag)

    if TAG_SENTINEL in rendered:
        print(
            f"ERROR: {TAG_SENTINEL} is still present — pass --tag or edit the template. "
            "Publishing it would point the runner at an image that does not exist.",
            file=sys.stderr,
        )
        return 2

    image_lines = [ln for ln in rendered.splitlines() if ln.startswith(f"{IMAGE_VAR}=")]
    if len(image_lines) != 1:
        print(
            f"ERROR: expected exactly one {IMAGE_VAR}= line, found {len(image_lines)}. "
            "The runner sources this file and reads that single variable.",
            file=sys.stderr,
        )
        return 2

    target = f"s3://{args.bucket}/{POINTER_KEY}"
    if args.dry_run:
        print(f"[DRY RUN] would publish -> {target}")
        print(f"          {image_lines[0]}")
        print("Dry run complete; nothing uploaded.")
        return 0

    assert client is not None
    client.put_object(Bucket=args.bucket, Key=POINTER_KEY, Body=rendered.encode("utf-8"))
    print(f"published -> {target}")
    print(f"  {image_lines[0]}")
    print("The runner picks this up on its next `sudo arag-ingest ...` — no restart, no apply.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
