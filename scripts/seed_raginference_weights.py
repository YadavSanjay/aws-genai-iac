#!/usr/bin/env python
"""Seed the RagInference weights S3 bucket from the local Hugging Face cache.

R2 data step. The RagInference Fargate task runs with ``MODEL_SOURCE=s3``: at
start it syncs ``MODEL_S3_URI`` into ``HF_HOME`` and then loads the models
OFFLINE (``HF_HUB_OFFLINE=1``). Offline, ``from_pretrained("<repo-id>")``
resolves ``repo-id -> refs/main -> snapshots/<commit>/``, so the bucket must be a
valid HF cache: a ``refs/main`` that points at a snapshot actually present.

This uploads the two service-default models straight from the local cache (no
re-download) and PINS ``refs/main`` to the snapshot it uploads:

* ``BAAI/bge-m3``             (dense+sparse embedder) -> ``5617a9f...``
* ``jinaai/jina-reranker-v3`` (listwise reranker)     -> ``050e171...``

Two deliberate choices:

* ``onnx/`` and ``openvino/`` are EXCLUDED — the torch service never loads them
  and onnx alone is ~2.2 GB of the bge snapshot. Mirrors
  ``RagInference/infra/download_models.py``'s ``IGNORE_PATTERNS``.
* ``refs/main`` is written by THIS script, not copied from the local cache: the
  local jina ``refs/main`` had drifted to a commit whose snapshot is not on disk
  (``10fb694...``), which would break offline resolution. Pinning it to the
  snapshot we upload keeps the bucket self-consistent.

Idempotent: objects already present with the same byte size are skipped, so a
re-run only uploads what changed and always re-pins ``refs/main``. After a model
refresh, update the snapshot hashes in ``MODELS`` and re-run.

Writes go as the pinned profile (default ``genai-tf``, the Terraform exec role).
Objects are encrypted with the project CMK via the bucket's default SSE-KMS — no
explicit SSE header, or the bucket's ``DenyNonKmsEncryption`` policy would reject
a non-KMS one.

Usage (from the repo root, py312 env)::

    conda run -n py312 --no-capture-output \\
        python scripts/seed_raginference_weights.py

    # dry run — list what would upload, touch nothing:
    conda run -n py312 python scripts/seed_raginference_weights.py --dry-run
"""

from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

# model dir name in the HF cache -> the snapshot commit that MUST be refs/main.
MODELS: list[tuple[str, str]] = [
    ("models--BAAI--bge-m3", "5617a9f61b028005a4858fdac845db406aefb181"),
    ("models--jinaai--jina-reranker-v3", "050e171c4f75dfec5b648ed8470a2475e5a30f30"),
]

# Framework exports the torch service never loads. Any path component matching
# these is skipped — mirrors download_models.py's IGNORE_PATTERNS.
EXCLUDE_DIRS = {"onnx", "openvino"}

DEFAULT_BUCKET = "genai-dev-raginference-weights-us-east-1"


def default_cache_hub() -> str:
    """Return the local HF hub cache, resolved the way ``huggingface_hub`` does.

    Returns:
        ``HF_HUB_CACHE`` if set, else ``<HF_HOME>/hub``, else the library's
        default under the home directory.
    """
    if hub := os.environ.get("HF_HUB_CACHE"):
        return hub
    hf_home = os.environ.get("HF_HOME") or str(Path.home() / ".cache" / "huggingface")
    return str(Path(hf_home) / "hub")


def _excluded(rel: Path) -> bool:
    return any(part in EXCLUDE_DIRS for part in rel.parts)


def _iter_snapshot_files(snapshot_dir: Path) -> Iterator[tuple[Path, Path]]:
    """Yield (local_path, path-relative-to-snapshot) for uploadable files."""
    for path in sorted(snapshot_dir.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(snapshot_dir)
        if _excluded(rel):
            continue
        yield path, rel


def _human(nbytes: int) -> str:
    size = float(nbytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", default=DEFAULT_BUCKET)
    parser.add_argument("--cache-hub", default=default_cache_hub())
    parser.add_argument("--profile", default="genai-tf", help="AWS profile to write as.")
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would upload and touch nothing.",
    )
    args = parser.parse_args(argv)

    cache_hub = Path(args.cache_hub)
    if not cache_hub.is_dir():
        print(f"ERROR: cache hub not found: {cache_hub}", file=sys.stderr)
        return 1

    # Validate every model/snapshot exists BEFORE uploading anything, so a typo
    # fails fast rather than half-seeding the bucket.
    plan: list[tuple[str, str, Path]] = []
    for name, snapshot in MODELS:
        snap_dir = cache_hub / name / "snapshots" / snapshot
        if not snap_dir.is_dir():
            print(f"ERROR: missing snapshot {snapshot} under {cache_hub / name}", file=sys.stderr)
            return 1
        plan.append((name, snapshot, snap_dir))

    client: Any = None
    if not args.dry_run:
        try:
            import boto3
        except ImportError:
            print("ERROR: boto3 is required (pip install boto3 into py312).", file=sys.stderr)
            return 1
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("s3")

    print(
        f"Seeding s3://{args.bucket}  (profile={args.profile}, region={args.region})"
        f"{'  [DRY RUN]' if args.dry_run else ''}"
    )

    total_up = total_skip = total_bytes = 0
    for name, snapshot, snap_dir in plan:
        key_prefix = f"hub/{name}/snapshots/{snapshot}"
        print(f"==> {name}  snapshot {snapshot}")
        for local_path, rel in _iter_snapshot_files(snap_dir):
            key = f"{key_prefix}/{rel.as_posix()}"
            size = local_path.stat().st_size

            if not args.dry_run and _same_size(client, args.bucket, key, size):
                total_skip += 1
                continue

            action = "would upload" if args.dry_run else "upload"
            print(f"    {action}  {rel.as_posix()}  ({_human(size)})")
            if not args.dry_run:
                # upload_file streams + multipart for the large weight files;
                # SSE is left to the bucket default (project CMK).
                client.upload_file(str(local_path), args.bucket, key)
            total_up += 1
            total_bytes += size

        # Pin refs/main to the snapshot we uploaded.
        ref_key = f"hub/{name}/refs/main"
        print(f"    pin  refs/main = {snapshot}")
        if not args.dry_run:
            client.put_object(
                Bucket=args.bucket,
                Key=ref_key,
                Body=snapshot.encode("ascii"),
                ContentType="text/plain",
            )

    print(
        f"\n{'Would upload' if args.dry_run else 'Uploaded'} {total_up} object(s) "
        f"({_human(total_bytes)}); skipped {total_skip} unchanged."
    )

    if not args.dry_run:
        _verify(client, args.bucket)
    return 0


def _same_size(client: Any, bucket: str, key: str, size: int) -> bool:
    """True if the object already exists with the same byte size (skip re-upload)."""
    from botocore.exceptions import ClientError

    try:
        head = client.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        if exc.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
            return False
        raise
    return int(head["ContentLength"]) == size


def _verify(client: Any, bucket: str) -> None:
    print("==> verify")
    paginator = client.get_paginator("list_objects_v2")
    count = size = 0
    for page in paginator.paginate(Bucket=bucket, Prefix="hub/"):
        for obj in page.get("Contents", []):
            count += 1
            size += obj["Size"]
    print(f"    bucket holds {count} object(s), {_human(size)} total")
    for name, _ in MODELS:
        body = client.get_object(Bucket=bucket, Key=f"hub/{name}/refs/main")["Body"].read()
        print(f"    refs/main  {name:<34} = {body.decode('ascii')}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
