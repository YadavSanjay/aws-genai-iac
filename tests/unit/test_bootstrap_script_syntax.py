"""Syntax-check EC2 bootstrap scripts and templates with `bash -n`.

A `data/qdrant` bootstrap shipped broken once: `$$(...)` in the Terraform
`templatefile` rendered to a literal `$$(` (Terraform only un-escapes `$${`),
which bash parses as PID `$$` followed by `(` — a syntax error that only
surfaced at first boot, failing the whole provision. `terraform validate` and
the `.tftpl` render both passed; nothing caught the *bash* mistake.

`bash -n` parses without executing, and a Terraform `${var}` is itself valid
bash parameter-expansion syntax, so checking the raw template catches this class
of error before an apply ever reaches a live instance. Bootstraps must stay
free of `%{ }` Terraform directives for this to hold (none use them today).
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULES = REPO_ROOT / "infra" / "modules"

# Bootstrap scripts (plain .sh) and templated bootstraps (user-data*.tftpl).
BOOTSTRAPS = sorted(
    {
        *MODULES.glob("**/user-data*.sh"),
        *MODULES.glob("**/user-data*.tftpl"),
    }
)

pytestmark = pytest.mark.skipif(
    shutil.which("bash") is None,
    reason="bash not on PATH; cannot run `bash -n` syntax check",
)


def test_bootstraps_discovered() -> None:
    """Guard against the glob silently matching nothing (which would pass vacuously)."""
    assert BOOTSTRAPS, f"no bootstrap scripts found under {MODULES}"


@pytest.mark.parametrize("script", BOOTSTRAPS, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_bootstrap_bash_syntax(script: Path) -> None:
    # Feed the script on stdin rather than as a path argument: on Windows the
    # backslash path would be mangled by Git Bash. `bash -n` with no file reads
    # and syntax-checks stdin. Normalize newlines and pipe BYTES so a Windows
    # text-mode pipe cannot reintroduce the \r that bash would choke on (the
    # files themselves are LF; this only guards the test harness).
    content = script.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    result = subprocess.run(
        ["bash", "-n"],
        input=content.encode("utf-8"),
        capture_output=True,
    )
    assert result.returncode == 0, (
        f"bash -n found a syntax error in {script.relative_to(REPO_ROOT)} "
        f"(a $$(...) over-escape in a templatefile would look like this):\n"
        f"{result.stderr.decode('utf-8', 'replace')}"
    )
