"""Gate the `readonlyagent` MCP read-only policy document.

`policies/iam/readonlyagent_mcp.json` is applied by an admin outside Terraform
(the exec role's guardrail denies `iam:*User*`), so nothing else validates it.
These checks run in `task ci` and catch the mistakes that are easy to make by
hand and confusing to debug in the console.

The headline one: the policy pairs an `Allow.Action` allow-list with a mirrored
`Deny.NotAction` backstop. Adding a read to only the `Allow` leaves the `Deny`
blocking it, and AWS reports "explicit deny in an identity-based policy" for a
permission you just granted.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

POLICY_PATH = Path(__file__).resolve().parents[2] / "policies" / "iam" / "readonlyagent_mcp.json"

# IAM managed-policy documents are capped at 6,144 characters excluding whitespace.
IAM_POLICY_SIZE_LIMIT = 6144

# Verbs that only read. `Simulate*` evaluates policies without changing anything.
READ_ONLY_VERBS = (
    "Describe",
    "Get",
    "List",
    "Filter",
    "StartQuery",
    "StopQuery",
    "View",
    "Generate",
    "Simulate",
)

# Reads that expose data rather than configuration. A wildcard that would swallow
# any of these is a defect, not a convenience.
FORBIDDEN_ACTIONS = {
    "s3:GetObject",
    "s3:Get*",
    "s3:*",
    "secretsmanager:GetSecretValue",
    "secretsmanager:Get*",
    "ssm:GetParameter",
    "ssm:GetParameters",
    "ssm:Get*",
    "dynamodb:GetItem",
    "dynamodb:Scan",
    "dynamodb:Query",
    "kms:Decrypt",
    "logs:GetLogEvents",
}


@pytest.fixture(scope="module")
def policy() -> dict[str, Any]:
    assert POLICY_PATH.is_file(), f"missing policy document: {POLICY_PATH}"
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def allow_stmt(policy: dict[str, Any]) -> dict[str, Any]:
    return next(s for s in policy["Statement"] if s["Effect"] == "Allow")


@pytest.fixture(scope="module")
def deny_stmt(policy: dict[str, Any]) -> dict[str, Any]:
    return next(s for s in policy["Statement"] if s["Effect"] == "Deny")


def test_allow_and_deny_lists_are_mirrored(
    allow_stmt: dict[str, Any], deny_stmt: dict[str, Any]
) -> None:
    """The single most important invariant in this file.

    `Deny.NotAction` must equal `Allow.Action` exactly. If they drift, the Deny
    blocks whatever the Allow just granted and the error message blames a missing
    permission rather than the real cause.
    """
    allow = allow_stmt["Action"]
    deny = deny_stmt["NotAction"]

    only_in_allow = sorted(set(allow) - set(deny))
    only_in_deny = sorted(set(deny) - set(allow))

    assert not only_in_allow, (
        f"granted in Allow.Action but missing from Deny.NotAction, so still denied: {only_in_allow}"
    )
    assert not only_in_deny, f"present in Deny.NotAction but never granted: {only_in_deny}"
    assert allow == deny, "lists match as sets but differ in order — keep them byte-identical"


def test_every_action_is_read_only(allow_stmt: dict[str, Any]) -> None:
    mutating = [
        a for a in allow_stmt["Action"] if not a.split(":", 1)[1].startswith(READ_ONLY_VERBS)
    ]
    assert not mutating, f"non-read actions in a read-only policy: {mutating}"


def test_no_data_plane_or_secret_reads(allow_stmt: dict[str, Any]) -> None:
    """Config reads are fine; reading bucket contents or secret values is not."""
    granted = set(allow_stmt["Action"])
    leaked = sorted(granted & FORBIDDEN_ACTIONS)
    assert not leaked, f"policy grants data-plane/secret reads: {leaked}"


def test_no_unscoped_service_wildcards(allow_stmt: dict[str, Any]) -> None:
    """`service:*` grants writes too. Every entry must name a verb."""
    bare = [a for a in allow_stmt["Action"] if a.endswith(":*")]
    assert not bare, f"service-wide wildcards grant writes: {bare}"


def test_no_duplicate_actions(allow_stmt: dict[str, Any]) -> None:
    actions = allow_stmt["Action"]
    dupes = sorted({a for a in actions if actions.count(a) > 1})
    assert not dupes, f"duplicate entries: {dupes}"


def test_statements_are_mcp_gated(allow_stmt: dict[str, Any], deny_stmt: dict[str, Any]) -> None:
    """Both statements must stay bound to the MCP request context.

    Dropping the Allow's condition would let the raw CLI use these grants,
    defeating the "reads go through MCP" rule in CLAUDE.md.
    """
    assert (
        allow_stmt["Condition"]["StringEquals"]["aws:CalledViaAWSMCP"] == "aws-mcp.amazonaws.com"
    ), "Allow is not pinned to the AWS MCP service principal"

    # A Bool operator on this String key never matches — the documented footgun.
    assert "Bool" not in allow_stmt["Condition"] or (
        "aws:CalledViaAWSMCP" not in allow_stmt["Condition"].get("Bool", {})
    ), "aws:CalledViaAWSMCP is a String key; a Bool operator never matches"

    assert deny_stmt["Condition"]["Bool"]["aws:ViaAWSMCPService"] == "true"


def test_document_fits_iam_size_limit(policy: dict[str, Any]) -> None:
    minified = json.dumps(policy, separators=(",", ":"))
    assert len(minified) <= IAM_POLICY_SIZE_LIMIT, (
        f"{len(minified)} chars exceeds the IAM managed-policy limit of {IAM_POLICY_SIZE_LIMIT}"
    )
