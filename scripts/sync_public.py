#!/usr/bin/env python
"""Stage the dev tree in the public clone as one snapshot.

Public history is one-way and snapshot-only: no dev commit or message crosses,
because dev messages routinely record real resource ids. This script exports the
committed dev tree, never the working tree, so gitignored files cannot come along.
It stops at `git add`. Review the staged diff, write a summary commit and push
by hand.

Run from anywhere; both paths are arguments so no machine path lives here:
    python scripts/sync_public.py --dev <dev-clone> --public <public-clone>
"""

from __future__ import annotations

import argparse
import io
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path


class SyncRefusedError(Exception):
    """A precondition failed, so nothing was changed or the result cannot be trusted."""


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    ).stdout.strip()


def repo_name(url: str) -> str:
    """Return the repository name from an HTTPS or SSH remote URL.

    Args:
        url: A remote URL such as `git@github.com:owner/name.git`.

    Returns:
        The final path segment without `.git`.
    """
    return url.rstrip("/").removesuffix(".git").replace(":", "/").rsplit("/", 1)[-1]


def _remote_names(repo: Path) -> set[str]:
    return {repo_name(line.split()[1]) for line in _git(repo, "remote", "-v").splitlines() if line}


def preflight(dev: Path, public: Path) -> None:
    """Refuse a sync that could publish the wrong thing.

    Args:
        dev: The dev clone.
        public: The public clone.

    Raises:
        SyncRefusedError: If the clones are mixed up, on the wrong branch or dirty.
    """
    if dev.resolve() == public.resolve():
        raise SyncRefusedError("--dev and --public are the same clone")
    for label, repo in (("dev", dev), ("public", public)):
        if _git(repo, "branch", "--show-current") != "main":
            raise SyncRefusedError(f"{label} clone is not on main")
        if _git(repo, "status", "--porcelain"):
            raise SyncRefusedError(f"{label} clone has uncommitted changes")
    public_names = _remote_names(public)
    if any(name.endswith("-dev") for name in public_names):
        raise SyncRefusedError("public clone has a remote pointing at a -dev repo")
    shared = public_names & _remote_names(dev)
    if shared:
        raise SyncRefusedError(f"both clones share a remote: {sorted(shared)}")


def check_dev_is_safe(dev: Path) -> None:
    """Run the public-safety check in dev, where the local denylist lives.

    The public clone has no denylist, so a check there would miss literal values.
    The tree comparison in `sync` ties this result to what gets staged.

    Args:
        dev: The dev clone.

    Raises:
        SyncRefusedError: If the check reports any finding.
    """
    result = subprocess.run(
        [sys.executable, str(dev / "scripts" / "check_public_safe.py")],
        cwd=dev,
        check=False,
    )
    if result.returncode != 0:
        raise SyncRefusedError("public-safety check failed in the dev clone")


def _replace_tree(dev: Path, public: Path) -> None:
    for child in public.iterdir():
        if child.name == ".git":
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    # autocrlf off on both sides keeps the stored bytes, so the trees can match exactly.
    archive = subprocess.run(
        ["git", "-C", str(dev), "-c", "core.autocrlf=false", "archive", "--format=tar", "HEAD"],
        capture_output=True,
        check=True,
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(public, filter="data")


def _stage(dev: Path, public: Path) -> None:
    # -f because every file here is tracked in dev, whatever the ignore rules say.
    _git(public, "-c", "core.autocrlf=false", "add", "-A", "-f", ".")
    for line in _git(dev, "ls-tree", "-r", "HEAD").splitlines():
        metadata, path = line.split("\t", 1)
        if metadata.startswith("100755"):
            _git(public, "update-index", "--chmod=+x", "--", path)


def sync(dev: Path, public: Path) -> str:
    """Replace the public tree with dev's committed tree and stage it.

    Args:
        dev: The dev clone.
        public: The public clone.

    Returns:
        The staged diff stat, empty when public already matches.

    Raises:
        SyncRefusedError: If a precondition fails or the staged tree differs from dev's.
    """
    preflight(dev, public)
    check_dev_is_safe(dev)
    _replace_tree(dev, public)
    _stage(dev, public)
    if _git(public, "write-tree") != _git(dev, "rev-parse", "HEAD^{tree}"):
        raise SyncRefusedError("staged tree differs from dev; inspect the public clone")
    return _git(public, "diff", "--cached", "--stat")


def main() -> int:
    """Parse arguments and run the sync.

    Returns:
        Process exit code: 0 on success, 1 when the sync was refused.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dev", type=Path, required=True, help="path to the dev clone")
    parser.add_argument("--public", type=Path, required=True, help="path to the public clone")
    args = parser.parse_args()
    try:
        stat = sync(args.dev, args.public)
    except SyncRefusedError as refused:
        print(f"sync refused: {refused}", file=sys.stderr)
        return 1
    print(stat or "public already matches dev")
    return 0


if __name__ == "__main__":
    sys.exit(main())
