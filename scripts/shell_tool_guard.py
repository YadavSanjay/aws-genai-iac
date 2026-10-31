#!/usr/bin/env python
"""PreToolUse hook: route Python tooling to the PowerShell tool, not Bash.

On this machine `conda` (and the project's Python toolchain) is on the PowerShell
PATH only. Running it through the Bash tool fails with `conda: command not found`,
or -- worse -- resolves a bare `python` that lacks the project's dependencies.

CLAUDE.md has said so from the start. It did not stop the mistake recurring, so
this makes it mechanical: the Bash tool refuses these binaries and names the fix.

Matcher should be `Bash` ONLY -- PowerShell is the correct venue and must stay free.
"""

from __future__ import annotations

import json
import re
import shlex
import sys

# Binaries that only resolve on the PowerShell PATH here.
POWERSHELL_ONLY = {
    "conda",
    "python",
    "python3",
    "py",
    "pytest",
    "ruff",
    "mypy",
    "pip",
    "pip3",
    "uv",
    "uvx",
}

SEPARATOR_TOKENS = {";", "|", "||", "&", "&&", "|&", "\n"}
WRAPPERS = {"&", "sudo", "env", "command", "exec", "time", "(", ")", "{", "}"}
ASSIGN_INLINE = re.compile(r"^\$?[\w:]+=")
ASSIGN_NAME = re.compile(r"^\$[\w:]+$")


def _basename(token: str) -> str:
    return token.lower().strip("\"'").split("\\")[-1].split("/")[-1].removesuffix(".exe")


def _segments(command: str) -> list[list[str]]:
    """Tokenize quote-aware, then split on separator TOKENS (not raw characters)."""
    lexer = shlex.shlex(command, posix=False, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()

    segments: list[list[str]] = [[]]
    for token in tokens:
        if token in SEPARATOR_TOKENS:
            segments.append([])
        else:
            segments[-1].append(token)
    return segments


def _invoked_binaries(command: str) -> set[str]:
    """The binary at the head of each segment -- not every token that looks like one."""
    found: set[str] = set()
    for tokens in _segments(command):
        i = 0
        while i < len(tokens):
            token = tokens[i]
            if ASSIGN_INLINE.match(token):
                i += 1
                continue
            if ASSIGN_NAME.match(token) and i + 1 < len(tokens) and tokens[i + 1] == "=":
                i += 3
                continue
            if _basename(token) in WRAPPERS:
                i += 1
                continue
            found.add(_basename(token))
            break
    return found


def main() -> None:
    try:
        payload = json.loads(sys.stdin.read())
    except (ValueError, TypeError):
        sys.exit(0)  # not our concern; the other guards fail closed

    if (payload.get("tool_name") or "") != "Bash":
        sys.exit(0)

    command = str((payload.get("tool_input") or {}).get("command") or "")
    if not command.strip():
        sys.exit(0)

    offenders = _invoked_binaries(command) & POWERSHELL_ONLY
    if not offenders:
        sys.exit(0)

    sys.stderr.write(
        f"BLOCKED by shell-tool-guard: `{', '.join(sorted(offenders))}` is not on the "
        "Bash PATH on this machine.\n"
        "\n"
        "Re-run this with the PowerShell tool instead. Conda and the project's Python\n"
        "toolchain resolve only there; via Bash you get 'command not found', or a bare\n"
        "`python` without the project's dependencies.\n"
        "\n"
        "Rule of thumb: PowerShell for Python/pytest/ruff/mypy/conda; Bash for POSIX\n"
        "and git glue (grep, find, sed, git).\n"
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
