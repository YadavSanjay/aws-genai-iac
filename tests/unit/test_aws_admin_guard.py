"""Tests for the aws-admin-guard PreToolUse hook.

The guard enforces the CLAUDE.md rule that the agent reaches AWS only as
`readonlyagent` / `genai-tf` / `tfuser` -- never as the human's admin identity,
and never with an unpinned profile (there is deliberately no `[default]`).

Note: the fixtures below deliberately contain admin-profile command strings. They
are inert as test data, but do not paste them into a live shell -- the guard would
(correctly) block that shell invocation.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
GUARD = REPO_ROOT / "scripts" / "aws_admin_guard.py"

BLOCKED = 2  # exit code that tells Claude Code to refuse the tool call
ALLOWED = 0

MCP_TOOL = "mcp__aws-mcp__aws___call_aws"


def run_guard(
    command: str, tool: str = "Bash", key: str = "command", project_dir: Path = REPO_ROOT
) -> int:
    """Invoke the hook exactly as Claude Code does: JSON on stdin, exit code out."""
    payload = json.dumps({"tool_name": tool, "tool_input": {key: command}})
    result = subprocess.run(
        [sys.executable, str(GUARD)],
        input=payload,
        capture_output=True,
        text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(project_dir)},
    )
    return result.returncode


@pytest.fixture
def pinned_project(tmp_path: Path) -> Path:
    """A project whose .mcp.json pins the server, as the gitignored real one does."""
    config = {"mcpServers": {"aws-mcp": {"env": {"AWS_PROFILE": "readonlyagent"}}}}
    (tmp_path / ".mcp.json").write_text(json.dumps(config), encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize(
    "command",
    [
        "$env:AWS_PROFILE = 'admin'; aws sts get-caller-identity",
        "$env:AWS_PROFILE = 'admin'; aws iam get-policy --policy-arn x",
        "$env:AWS_PROFILE = 'admin'; terragrunt plan --working-dir infra",
        "$env:AWS_PROFILE = 'admin'; task iam-baseline",
        "aws --profile admin dynamodb delete-table --table-name x",
        "$env:AWS_PROFILE = 'admin'; & aws iam get-policy --policy-arn x",
    ],
)
def test_admin_identity_is_blocked_even_for_reads(command: str) -> None:
    assert run_guard(command) == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        "aws sts get-caller-identity",
        "aws iam create-access-key --user-name tfuser",
        "terragrunt apply --working-dir infra/environments/dev/00-networking",
        "$env:AWS_PROFILE = 'someoneelse'; aws s3 ls",
        "$r = & aws sts get-caller-identity",
    ],
)
def test_unpinned_or_unknown_profile_is_blocked(command: str) -> None:
    assert run_guard(command) == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        "$env:AWS_PROFILE = 'readonlyagent'; aws sts get-caller-identity",
        "$env:AWS_PROFILE = 'genai-tf'; terragrunt apply --working-dir infra",
        '$env:AWS_PROFILE = "genai-tf"; & "D:\\Tools\\Terraform\\terragrunt\\terragrunt.exe" '
        "state list --working-dir infra",
    ],
)
def test_scoped_identities_are_allowed(command: str) -> None:
    assert run_guard(command) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        "terragrunt hcl fmt --check --working-dir infra",
        "terraform fmt -check -recursive infra/modules",
        '& "D:\\Tools\\Terraform\\terragrunt\\terragrunt.exe" hcl fmt --check --working-dir infra',
        "aws configure list-profiles",
        "task ci",
        "conda run -n py312 ruff check scripts/",
        "git status --short",
    ],
)
def test_commands_that_never_reach_aws_need_no_profile(command: str) -> None:
    assert run_guard(command) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        # The word "task"/"terraform" appearing as an argument or inside a string is
        # not an invocation. Regression: `Get-Command task` was once blocked.
        'try { "task: " + (Get-Command task -ErrorAction Stop).Source } catch { "no" }',
        "Get-Command terraform",
        "grep -rn 'aws sts get-caller-identity' docs/",
        "echo 'run: task apply'",
    ],
)
def test_binary_names_in_arguments_are_not_invocations(command: str) -> None:
    assert run_guard(command) == ALLOWED


@pytest.mark.parametrize(
    "command",
    [
        # The exact call that went wrong: a read issued on the raw CLI. It returned
        # AccessDenied (condition-gated to MCP), which was misread as a missing
        # permission and "fixed" by escalating to the admin profile.
        "$env:AWS_PROFILE = 'readonlyagent'; aws iam get-policy --policy-arn x",
        "$env:AWS_PROFILE = 'readonlyagent'; aws iam get-policy-version --policy-arn x",
        "$env:AWS_PROFILE = 'readonlyagent'; aws ec2 describe-vpcs",
        "$env:AWS_PROFILE = 'genai-tf'; aws iam list-roles",
        "aws --profile readonlyagent s3 ls",
    ],
)
def test_raw_cli_reads_must_go_through_mcp(command: str) -> None:
    assert run_guard(command) == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        # Identity verification: needs no IAM permission, and MCP can only ever
        # report its own pinned profile -- so the raw CLI is the only way.
        "$env:AWS_PROFILE = 'genai-tf'; aws sts get-caller-identity --query Arn",
        "$env:AWS_PROFILE = 'readonlyagent'; aws sts get-caller-identity",
        # Writes MCP cannot perform, on the provisioning path.
        "$env:AWS_PROFILE = 'genai-tf'; aws s3api copy-object --bucket b --key k "
        "--copy-source b/old",
        "$env:AWS_PROFILE = 'genai-tf'; aws s3api delete-object --bucket b --key k",
    ],
)
def test_legitimate_raw_cli_paths_still_allowed(command: str) -> None:
    assert run_guard(command) == ALLOWED


def test_mcp_reads_are_unaffected_by_the_channel_rule(pinned_project: Path) -> None:
    """The rule targets the raw CLI only -- MCP is the prescribed channel."""
    code = run_guard(
        "aws ec2 describe-vpcs", tool=MCP_TOOL, key="cli_command", project_dir=pinned_project
    )
    assert code == ALLOWED


def test_mcp_inherits_env_pinned_profile(pinned_project: Path) -> None:
    """.mcp.json pins AWS_PROFILE=readonlyagent, so an unpinned cli_command is fine."""
    code = run_guard(
        "aws iam list-roles", tool=MCP_TOOL, key="cli_command", project_dir=pinned_project
    )
    assert code == ALLOWED


def test_mcp_without_a_pinned_config_fails_closed(tmp_path: Path) -> None:
    """No .mcp.json means the identity cannot be resolved, so it is refused."""
    code = run_guard("aws iam list-roles", tool=MCP_TOOL, key="cli_command", project_dir=tmp_path)
    assert code == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        "aws iam list-roles --profile admin",
        "aws iam delete-policy --profile admin --policy-arn x",
    ],
)
def test_mcp_profile_override_to_admin_is_blocked(command: str) -> None:
    """A --profile inside cli_command overrides the server env -- guard it."""
    assert run_guard(command, tool=MCP_TOOL, key="cli_command") == BLOCKED


def test_unparseable_input_fails_closed() -> None:
    result = subprocess.run(
        [sys.executable, str(GUARD)],
        input="not json",
        capture_output=True,
        text=True,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    assert result.returncode == BLOCKED


@pytest.mark.parametrize(
    "command",
    [
        # Regression: a separator inside a QUOTED argument is data, not a command
        # boundary. `grep -e "go-task\|task (optional)"` once parsed as a `task`
        # invocation and was wrongly blocked.
        r'grep -rni -e "go-task\|task (optional)" --include=*.md .',
        "grep -rn -e 'aws sts get-caller-identity|terragrunt apply' docs/",
        r'rg "terraform apply|terragrunt destroy" scripts/',
    ],
)
def test_separator_inside_quotes_is_not_a_command_boundary(command: str) -> None:
    assert run_guard(command) == ALLOWED
