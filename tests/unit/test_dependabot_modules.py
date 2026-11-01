"""Dependabot's Terraform update lists every module folder, by exact path.

A glob here failed the whole update with `/infra/modules/** not found`, because it stopped
at the category folders. The explicit list that replaced it goes stale silently when a module
is added, so this compares it with the real tree. Static checks on committed files.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "dependabot.yml"


def _listed() -> list[str]:
    return re.findall(r"^\s+- (/infra/modules/\S+)$", CONFIG.read_text(encoding="utf-8"), re.M)


def test_every_module_is_listed_and_every_entry_is_a_module() -> None:
    modules = {
        "/" + path.parent.relative_to(ROOT).as_posix()
        for path in (ROOT / "infra" / "modules").rglob("versions.tf")
        if ".terragrunt-cache" not in path.parts
    }

    assert modules, "no modules found, so this test would prove nothing"
    assert set(_listed()) == modules


def test_entries_are_exact_paths_without_duplicates() -> None:
    listed = _listed()

    assert len(listed) == len(set(listed))
    assert not [entry for entry in listed if "*" in entry]
