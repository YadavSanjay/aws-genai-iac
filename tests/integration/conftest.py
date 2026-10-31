"""Shared fixtures for post-apply verification.

The estate has a park switch (`parked` in infra/environments/dev/env.hcl) that
holds every compute tier down indefinitely to stop a fixed credit balance from
draining while nobody is demoing. Schedule assertions therefore cannot hardcode
ENABLED: the correct state depends on what the environment declares.

Reading the switch from the committed HCL — rather than taking whatever AWS
currently reports — is the point. It makes these tests a drift check in both
directions: parked config with a live start schedule fails, and unparked config
with a disabled one fails too. A test that simply mirrored the AWS state back at
itself would assert nothing.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DEV_ENV_HCL = REPO_ROOT / "infra/environments/dev/env.hcl"

# Matches `parked = true` on a non-comment line. HCL has no significant leading
# whitespace here, and the value is a bare bool by construction.
_PARKED = re.compile(r"^\s*parked\s*=\s*(true|false)\s*$", re.MULTILINE)
_INGRESS_MODE = re.compile(r"^\s*ingress_mode\s*=\s*\"(\w+)\"\s*$", re.MULTILINE)


def _declarations() -> str:
    """dev/env.hcl with comment-only lines removed.

    The switches are documented at length in that file, and the prose names the
    very values being matched ("`ingress_mode` governs how the estate is
    reached"). Matching raw text would read a sentence about a switch as the
    switch itself.
    """
    return "\n".join(
        line
        for line in DEV_ENV_HCL.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    )


def env_parked() -> bool:
    """Whether dev/env.hcl declares the environment parked.

    Fails loudly rather than defaulting: a missing or renamed switch would
    otherwise silently turn every park-aware assertion into "expect running",
    which is exactly the state the switch exists to prevent.
    """
    match = _PARKED.search(_declarations())
    if match is None:
        raise AssertionError(
            f"no `parked = true|false` found in {DEV_ENV_HCL}. The park switch is "
            "the source of truth for every schedule assertion; if it was renamed, "
            "update this helper rather than dropping the check."
        )
    return match.group(1) == "true"


def env_ingress_mode() -> str:
    """Whether the environment declares "alb" or "ssm" ingress.

    Read from the committed HCL for the same reason `parked` is. This previously
    defaulted to "alb" from an unset environment variable, so the toggle's
    headline assertion — that flipping to "ssm" actually DESTROYS the load
    balancer rather than leaving it billing — failed on every ordinary run and
    had to be ignored. An assertion nobody can act on is not a check.
    """
    match = _INGRESS_MODE.search(_declarations())
    if match is None:
        raise AssertionError(f'no `ingress_mode = "..."` found in {DEV_ENV_HCL}')
    return match.group(1)


@pytest.fixture(scope="session")
def parked() -> bool:
    return env_parked()


@pytest.fixture(scope="session")
def ingress_mode() -> str:
    return env_ingress_mode()


@pytest.fixture(scope="session")
def expected_schedule_state(parked: bool) -> str:
    """State every EC2 start/stop schedule should be in for the declared mode."""
    return "DISABLED" if parked else "ENABLED"
