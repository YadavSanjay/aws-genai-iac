#!/usr/bin/env python
"""Fail if a tracked file holds something that must not reach the public repo.

Run by `task lint` and pre-commit. Works on a clean clone from patterns alone. On
a machine with the gitignored local files it also rejects the real values from
`infra/account.local.hcl` and any literals listed in `.public-denylist` (one per
line), matched case-insensitively.

Findings report the file, line and kind, never the matched text, so a hit does
not copy the value into a CI log.

This catches known shapes and known values. It cannot catch something personal
written in plain prose, so it does not replace reading the diff before a sync.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

PATTERNS = {
    "machine path": re.compile(r"\b[A-Za-z]:[\\/](?:Tools|Users|Program Files)\b"),
    "home directory": re.compile(r"/(?:Users|home)/[A-Za-z]\w+/"),
    "access key": re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}
AWS_RESOURCE_ID = re.compile(r"\b(?:i|vpc|subnet|sg|vol|ami)-([0-9a-f]{8,17})\b")
ACCOUNT_ID = re.compile(r"\b\d{12}\b")
PLACEHOLDER_ACCOUNTS = {"000000000000", "111122223333"}

# The copyright line legitimately carries the author's name.
LITERAL_EXEMPT = {"LICENSE"}
BINARY_SUFFIXES = {".png"}


def load_literals(repo: Path) -> list[str]:
    """Return the real values to reject, read from the gitignored local files.

    Args:
        repo: Repository root.

    Returns:
        Lower-cased literals; empty on a machine without the local files.
    """
    literals: list[str] = []
    account_local = repo / "infra" / "account.local.hcl"
    if account_local.is_file():
        for line in account_local.read_text(encoding="utf-8").splitlines():
            if line.lstrip().startswith("#") or re.match(r"\s*region\b", line):
                continue
            literals.extend(re.findall(r'"([^"]+)"', line))
    denylist = repo / ".public-denylist"
    if denylist.is_file():
        literals.extend(denylist.read_text(encoding="utf-8").split("\n"))
    return [value.strip().lower() for value in literals if value.strip()]


def _is_mock_id(hex_part: str) -> bool:
    """Tell a Terragrunt mock id (zero-padded or one repeated digit) from a real one."""
    return hex_part.startswith("00000000") or len(set(hex_part)) == 1


def scan_line(line: str, literals: list[str]) -> list[str]:
    """Return the kinds of problem found on one line.

    Args:
        line: The line to check.
        literals: Lower-cased values to reject.

    Returns:
        The kind of each problem found; empty when the line is clean.
    """
    kinds = [kind for kind, pattern in PATTERNS.items() if pattern.search(line)]
    if not all(_is_mock_id(match.group(1)) for match in AWS_RESOURCE_ID.finditer(line)):
        kinds.append("AWS resource id")
    if set(ACCOUNT_ID.findall(line)) - PLACEHOLDER_ACCOUNTS:
        kinds.append("account id")
    lowered = line.lower()
    if any(value in lowered for value in literals):
        kinds.append("denylisted value")
    return kinds


def scan_file(path: Path, relative: str, literals: list[str]) -> list[str]:
    """Return one finding per problem in a file.

    Args:
        path: The file on disk.
        relative: Its repo-relative path, used in findings.
        literals: Lower-cased values to reject.

    Returns:
        Findings in `path:line: kind` form.
    """
    if path.suffix in BINARY_SUFFIXES:
        return []
    active = [] if relative in LITERAL_EXEMPT else literals
    text = path.read_text(encoding="utf-8", errors="replace")
    return [
        f"{relative}:{number}: {kind}"
        for number, line in enumerate(text.splitlines(), 1)
        for kind in scan_line(line, active)
    ]


def main() -> int:
    """Scan every tracked file.

    Returns:
        Process exit code: 0 when clean, 1 when anything was found.
    """
    tracked = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    literals = load_literals(REPO_ROOT)
    findings = [
        finding
        for relative in tracked
        if (REPO_ROOT / relative).is_file()
        for finding in scan_file(REPO_ROOT / relative, relative, literals)
    ]
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        print(f"check-public-safe: {len(findings)} finding(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
