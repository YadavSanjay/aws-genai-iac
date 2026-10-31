"""Tests for the shell-tool-guard PreToolUse hook.

`conda` and the project's Python toolchain resolve only on the PowerShell PATH.
Running them through the Bash tool fails, or silently picks up a bare `python`
without the project's dependencies. CLAUDE.md said so and the mistake still
recurred, so the hook enforces it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "shell_tool_guard.py"

BLOCKED = 2
ALLOWED = 0


def run_guard(command: str, tool: str = "Bash") -> int:
    payload = json.dumps({"tool_name": tool, "tool_input": {"command": command}})
    result = subprocess.run(
        [sys.executable, str(GUARD)],
        input=payload,
        capture_output=True,
        text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    return result.returncode


@pytest.mark.parametrize(
    "command",
    [
        # The exact recurring mistake.
        "conda run -n py312 pytest tests/unit/ -q",
        "conda run -n py312 ruff check scripts tests",
        "conda run -n py312 mypy scripts --ignore-missing-imports",
        "pytest tests/unit/",
        "python scripts/aws_admin_guard.py",
        "ruff check .",
        "pip install -e .",
        # Still caught after a cd or an env assignment.
        "cd /d/repo && conda run -n py312 pytest",
        "PYTHONPATH=src python -m iac",
    ],
)
def test_powershell_only_binaries_are_blocked_in_bash(command: str) -> None:
    assert run_guard(command) == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        "git status --short",
        "grep -rn 'conda run' docs/",
        "find . -name '*.tf'",
        "sed -n '1,20p' README.md",
        "ls -la",
        # Mentioning a binary as an argument is not invoking it.
        "echo 'use conda run -n py312 pytest'",
        "git log --oneline -- scripts/shell_tool_guard.py",
    ],
)
def test_posix_glue_is_allowed_in_bash(command: str) -> None:
    assert run_guard(command) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        "conda run -n py312 pytest tests/unit/ -q",
        "python scripts/aws_admin_guard.py",
    ],
)
def test_powershell_tool_is_never_restricted(command: str) -> None:
    """PowerShell is the correct venue -- the guard must not touch it."""
    assert run_guard(command, tool="PowerShell") == ALLOWED


def test_other_tools_are_ignored() -> None:
    assert run_guard("conda run -n py312 pytest", tool="Edit") == ALLOWED
