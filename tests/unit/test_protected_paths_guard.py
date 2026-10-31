"""Tests for the protected-paths PreToolUse hook.

The hook exists so the agent cannot weaken its own AWS identity guard -- the
cheapest escalation route is editing the guard rather than defeating it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "protected_paths_guard.py"

BLOCKED = 2
ALLOWED = 0


def run_guard(tool: str, tool_input: dict[str, str]) -> int:
    payload = json.dumps({"tool_name": tool, "tool_input": tool_input})
    result = subprocess.run(
        [sys.executable, str(GUARD)],
        input=payload,
        capture_output=True,
        text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    return result.returncode


@pytest.mark.parametrize(
    "relative",
    [
        "scripts/aws_admin_guard.py",
        "scripts/protected_paths_guard.py",
        "tests/unit/test_aws_admin_guard.py",
        ".claude/settings.json",
        ".mcp.json",
    ],
)
@pytest.mark.parametrize("tool", ["Edit", "Write"])
def test_editing_a_safety_control_is_blocked(relative: str, tool: str) -> None:
    target = str(REPO_ROOT / relative)
    assert run_guard(tool, {"file_path": target}) == BLOCKED


def test_editing_the_aws_credentials_file_is_blocked() -> None:
    target = str(Path.home() / ".aws" / "credentials")
    assert run_guard("Write", {"file_path": target}) == BLOCKED


@pytest.mark.parametrize(
    "relative",
    [
        "infra/root.hcl",
        "src/iac/cli.py",
        "docs/runbooks/terraform-execution-role.md",
        "CLAUDE.md",
    ],
)
def test_ordinary_project_files_remain_editable(relative: str) -> None:
    target = str(REPO_ROOT / relative)
    assert run_guard("Edit", {"file_path": target}) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        "echo 'ALLOWED_PROFILES = {\"admin\"}' > scripts/aws_admin_guard.py",
        "rm scripts/aws_admin_guard.py",
        "Set-Content .claude/settings.json -Value '{}'",
        "git checkout HEAD~1 -- scripts/aws_admin_guard.py",
        "mv /tmp/x .mcp.json",
    ],
)
def test_shell_writes_to_safety_controls_are_blocked(command: str) -> None:
    assert run_guard("Bash", {"command": command}) == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        # Reading them is fine -- only writes are the problem.
        "cat scripts/aws_admin_guard.py",
        "conda run -n py312 pytest tests/unit/test_aws_admin_guard.py -q",
        "git status --short",
        "echo hello > /tmp/scratch.txt",
    ],
)
def test_reads_and_unrelated_writes_are_allowed(command: str) -> None:
    assert run_guard("Bash", {"command": command}) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        # Regression: `2>&1` contains ">", so an earlier version blocked ANY command
        # that merely redirected stderr while naming a protected file -- including
        # running the guard's own tests. Redirection is judged by its TARGET.
        "conda run -n py312 pytest tests/unit/test_aws_admin_guard.py -q 2>&1",
        "python scripts/aws_admin_guard.py < payload.json 2>&1",
        "ruff check scripts/protected_paths_guard.py 2>&1 | tail -5",
        "git diff .claude/settings.json 2>&1",
    ],
)
def test_stderr_redirection_is_not_a_write_to_the_named_file(command: str) -> None:
    assert run_guard("Bash", {"command": command}) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        # ...but a redirect whose TARGET is protected must still block, including
        # when stderr redirection appears in the same command.
        "echo x > scripts/aws_admin_guard.py 2>&1",
        "echo x >> .claude/settings.json",
        "cat evil.py > scripts/protected_paths_guard.py",
    ],
)
def test_redirection_onto_a_protected_target_still_blocks(command: str) -> None:
    assert run_guard("Bash", {"command": command}) == BLOCKED


def test_unparseable_input_fails_closed() -> None:
    result = subprocess.run(
        [sys.executable, str(GUARD)],
        input="not json",
        capture_output=True,
        text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    assert result.returncode == BLOCKED
