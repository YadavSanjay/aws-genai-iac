"""The public sync stages dev's exact tree, carries no history, and refuses bad states.

These run real git in temporary repositories and the real public-safety check.
"""

from __future__ import annotations

import importlib.util
import shutil
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
PUBLIC_URL = "https://github.com/example/widget.git"
DEV_URL = "https://github.com/example/widget-dev.git"


def _load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("sync_public", SCRIPTS / "sync_public.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sync_public = _load()


def _git(repo: Path, *args: str) -> str:
    identity = ("-c", "user.name=test", "-c", "user.email=test@example.com")
    return subprocess.run(
        ["git", "-C", str(repo), *identity, *args],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def _init(repo: Path) -> Path:
    repo.mkdir()
    _git(repo, "init", "-b", "main")
    return repo


@pytest.fixture
def dev(tmp_path: Path) -> Path:
    repo = _init(tmp_path / "dev")
    (repo / "scripts").mkdir()
    shutil.copy(SCRIPTS / "check_public_safe.py", repo / "scripts")
    (repo / "run.sh").write_text("#!/bin/sh\n", encoding="utf-8")
    (repo / "run.sh").chmod(0o755)  # Linux tracks the file mode, and a mismatch reads as dirty.
    (repo / ".gitignore").write_text("*.local\n.public-denylist\n", encoding="utf-8")
    (repo / "notes.local").write_text("private\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "update-index", "--chmod=+x", "run.sh")
    _git(repo, "commit", "-m", "dev only message")
    _git(repo, "remote", "add", "origin", DEV_URL)
    return repo


@pytest.fixture
def public(tmp_path: Path) -> Path:
    repo = _init(tmp_path / "public")
    (repo / "stale.txt").write_text("old\n", encoding="utf-8")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "first public commit")
    _git(repo, "remote", "add", "origin", PUBLIC_URL)
    return repo


def test_staged_tree_is_exactly_the_dev_tree(dev: Path, public: Path) -> None:
    assert "stale.txt" in sync_public.sync(dev, public)

    assert _git(public, "write-tree") == _git(dev, "rev-parse", "HEAD^{tree}")
    assert "100755" in _git(public, "ls-files", "-s", "run.sh")
    assert not (public / "stale.txt").exists()


def test_no_dev_history_and_no_commit(dev: Path, public: Path) -> None:
    sync_public.sync(dev, public)

    assert _git(public, "log", "--format=%s") == "first public commit"
    assert _git(public, "remote", "get-url", "origin") == PUBLIC_URL


def test_gitignored_dev_files_stay_behind(dev: Path, public: Path) -> None:
    sync_public.sync(dev, public)

    assert not (public / "notes.local").exists()


def test_second_sync_is_empty(dev: Path, public: Path) -> None:
    sync_public.sync(dev, public)
    _git(public, "commit", "-m", "snapshot")

    assert sync_public.sync(dev, public) == ""


def _assert_refused(dev: Path, public: Path, match: str) -> None:
    before = _git(public, "status", "--porcelain")
    with pytest.raises(sync_public.SyncRefusedError, match=match):
        sync_public.sync(dev, public)
    assert _git(public, "status", "--porcelain") == before


def test_refuses_dirty_dev(dev: Path, public: Path) -> None:
    (dev / "run.sh").write_text("#!/bin/sh\necho changed\n", encoding="utf-8")
    _assert_refused(dev, public, "dev clone has uncommitted")


def test_refuses_dirty_public(dev: Path, public: Path) -> None:
    (public / "stale.txt").write_text("edited\n", encoding="utf-8")
    _assert_refused(dev, public, "public clone has uncommitted")


def test_refuses_wrong_branch(dev: Path, public: Path) -> None:
    _git(dev, "switch", "-c", "side")
    _assert_refused(dev, public, "dev clone is not on main")


def test_refuses_public_clone_pointing_at_dev(dev: Path, public: Path) -> None:
    _git(public, "remote", "add", "dev", "git@github.com:example/widget-dev.git")
    _assert_refused(dev, public, "pointing at a -dev repo")


def test_refuses_dev_clone_with_public_remote(dev: Path, public: Path) -> None:
    _git(dev, "remote", "add", "public", "git@github.com:example/widget.git")
    _assert_refused(dev, public, "share a remote")


def test_refuses_same_clone(dev: Path) -> None:
    with pytest.raises(sync_public.SyncRefusedError, match="same clone"):
        sync_public.sync(dev, dev)


def test_refuses_a_tracked_leak(dev: Path, public: Path) -> None:
    (dev / "leak.txt").write_text("key " + "AKIA" + "ABCDEFGHIJKLMNOP\n", encoding="utf-8")
    _git(dev, "add", ".")
    _git(dev, "commit", "-m", "oops")
    _assert_refused(dev, public, "public-safety check failed")


def test_refuses_a_denylisted_value_only_dev_knows(dev: Path, public: Path) -> None:
    (dev / ".public-denylist").write_text("some.person\n", encoding="utf-8")
    (dev / "leak.txt").write_text("owner Some.Person\n", encoding="utf-8")
    _git(dev, "add", "leak.txt")
    _git(dev, "commit", "-m", "oops")
    _assert_refused(dev, public, "public-safety check failed")


@pytest.mark.parametrize(
    ("url", "name"),
    [
        ("https://github.com/owner/name.git", "name"),
        ("https://github.com/owner/name", "name"),
        ("git@github.com:owner/name-dev.git", "name-dev"),
        ("git@github.com:name.git", "name"),
    ],
)
def test_repo_name(url: str, name: str) -> None:
    assert sync_public.repo_name(url) == name
