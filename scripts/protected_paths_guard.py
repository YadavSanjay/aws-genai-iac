#!/usr/bin/env python
"""PreToolUse hook: the agent may not edit its own safety controls.

`aws_admin_guard.py` only helps if the agent cannot weaken it. Without this, the
cheapest way past any guard is to edit the guard -- add a profile to the
allow-list, delete a test, or drop the hook wiring from settings.json. That is
privilege escalation by a different route, and it is the one an agent is most
likely to take because it looks like ordinary refactoring.

So these files are read-only to the agent. Changes to them are the human's call.

Covers Edit/Write/NotebookEdit directly. Shell writes are caught on a best-effort
basis (redirection, Set-Content, rm/mv/cp, git restore) -- a determined bypass via
an obfuscated shell command is still possible, which is why the substantive
protection is that these files are small, committed, and reviewed.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

# Repo-relative paths whose contents gate what the agent may do.
PROTECTED_RELATIVE = {
    "scripts/aws_admin_guard.py",  # the AWS identity allow-list
    "scripts/protected_paths_guard.py",  # this file
    "tests/unit/test_aws_admin_guard.py",  # proves the guard still works
    ".claude/settings.json",  # hook wiring
    ".claude/settings.local.json",
    ".mcp.json",  # MCP server profile pinning
}

# Absolute paths outside the repo: the real AWS credential store.
PROTECTED_ABSOLUTE = {
    Path.home() / ".aws" / "config",
    Path.home() / ".aws" / "credentials",
}

# Verbs that rewrite or remove whatever their arguments point at. When one of
# these appears, every path-ish token in the command is suspect.
SHELL_WRITE_VERB = re.compile(
    r"(set-content|add-content|out-file|\btee\b|\brm\b|remove-item|\bmv\b|move-item"
    r"|ruff format|black|terraform fmt"
    r"|\bcp\b|copy-item|git\s+(checkout|restore|clean)|truncate|sed\s+-i)",
    re.IGNORECASE,
)

# Redirection: only the TARGET matters, never mere co-occurrence of ">".
# `pytest test_aws_admin_guard.py 2>&1` redirects to "&1" -- harmless. An earlier
# version tested "contains > AND mentions a protected file", which blocked every
# command that merely redirected stderr while naming one. Match the target itself.
REDIRECT_TARGET = re.compile(r">>?\s*([^\s;|&]+)")

TOKEN_SPLIT = re.compile(r"[\s;|&]+")


def _fail(target: str, how: str) -> None:
    sys.stderr.write(
        f"BLOCKED by protected-paths-guard: {how} a safety control.\n"
        f"  Target: {target}\n"
        "\n"
        "This file governs which AWS identities the agent may use, or proves that\n"
        "governance still works. The agent must not modify it -- editing the guard is\n"
        "escalation, even when it looks like routine refactoring.\n"
        "\n"
        "If a change is genuinely needed:\n"
        "  1. Explain what should change and why.\n"
        "  2. Let the user make the edit, or have them temporarily remove the hook.\n"
        "Do not work around this by writing the file through a shell.\n"
    )
    sys.exit(2)


def _protected_hit(raw_path: str) -> str | None:
    """Return a human-readable match if raw_path is protected, else None."""
    if not raw_path:
        return None
    candidate = Path(raw_path.strip("\"'"))
    try:
        resolved = candidate.resolve()
    except (OSError, ValueError):
        resolved = candidate

    for absolute in PROTECTED_ABSOLUTE:
        try:
            if resolved == absolute.resolve():
                return str(absolute)
        except (OSError, ValueError):
            continue

    normalized = resolved.as_posix().lower()
    for relative in PROTECTED_RELATIVE:
        if normalized.endswith("/" + relative.lower()):
            return relative
    return None


def main() -> None:
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, TypeError):
        sys.stderr.write("protected-paths-guard: unparseable input; blocking.\n")
        sys.exit(2)

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    if tool_name in {"Edit", "Write", "NotebookEdit", "MultiEdit"}:
        hit = _protected_hit(str(tool_input.get("file_path") or ""))
        if hit:
            _fail(hit, "attempted to edit")
        sys.exit(0)

    command = str(tool_input.get("command") or "")
    if not command:
        sys.exit(0)

    # Only paths the command could actually write to are suspect -- redirection
    # targets always, plus every token when a destructive verb is present.
    suspects: list[str] = REDIRECT_TARGET.findall(command)
    if SHELL_WRITE_VERB.search(command):
        suspects.extend(TOKEN_SPLIT.split(command))

    for suspect in (s.replace("\\", "/").strip("\"'").lower() for s in suspects):
        if not suspect:
            continue
        for relative in PROTECTED_RELATIVE:
            lowered = relative.lower()
            if suspect.endswith(lowered) or suspect == lowered.split("/")[-1]:
                _fail(relative, "attempted to write, via a shell command,")
        for absolute in PROTECTED_ABSOLUTE:
            tail = f"{absolute.parent.name}/{absolute.name}".lower()
            if suspect.endswith(tail):
                _fail(str(absolute), "attempted to write, via a shell command,")

    sys.exit(0)


if __name__ == "__main__":
    main()
