#!/usr/bin/env python
"""PreToolUse hook: the agent may reach AWS ONLY as a scoped, non-admin identity.

House rule (see CLAUDE.md -> "AWS credential rule"): Claude Code uses
`readonlyagent` (reads) and `genai-tf`/`tfuser` (provisioning). It never uses the
human's admin identity -- not even for reads. Admin work is described and handed
to the human, who runs it themselves.

This is an ALLOW-LIST, not a block-list: any command that reaches AWS must pin one
of ALLOWED_PROFILES. An unpinned command is blocked too -- `[default]` has been
removed from ~/.aws/config precisely so unpinned calls fail closed, and this hook
catches them before they even run.

Covers Bash, PowerShell, and the AWS MCP tool -- the MCP server is pinned to
`readonlyagent` via env, but a `--profile` inside its `cli_command` would override
that, so it is guarded too.

Fails CLOSED: anything it cannot confidently clear is blocked.
Stdlib only -- it runs on whatever `python` the hook shell resolves.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

# The ONLY identities the agent may use. Everything else -- including any admin
# identity and any unpinned/ambient identity -- is refused.
ALLOWED_PROFILES = {"readonlyagent", "genai-tf", "tfuser"}

# Identities that carry standing privilege, called out for a clearer message.
ADMIN_PROFILES = {"default", "admin", "root"}

COMMAND_KEYS = ("command", "cli_command")

PROFILE_PATTERNS = (
    r"\$env:AWS_PROFILE\s*=\s*['\"]?([\w.@-]+)",  # PowerShell
    r"\bAWS_PROFILE\s*=\s*['\"]?([\w.@-]+)",  # bash inline / export
    r"--profile[=\s]+['\"]?([\w.@-]+)",  # explicit CLI flag
)

# Subcommands that never contact AWS, so they need no credentials at all.
# Matched against the FIRST positional argument (see _flagless).
AWS_LOCAL_ONLY = {"configure", "help"}

# Raw-CLI reads that stay legitimate. `sts get-caller-identity` needs no IAM
# permission and is the only way to verify which identity a profile resolves to --
# the MCP server can only ever report its own pinned profile.
CLI_READ_EXEMPT = {("sts", "get-caller-identity")}
TF_LOCAL_ONLY = {"fmt", "hcl", "version", "providers", "graph", "validate"}
TASK_LOCAL_ONLY = {"ci", "lint", "test", "fmt", "policy"}

# Flags that consume the NEXT token as their value. Without this, `--working-dir
# infra` makes "infra" look like a subcommand and local-only commands get blocked.
VALUE_FLAGS = {
    "--profile",
    "--region",
    "--output",
    "--query",
    "--endpoint-url",
    "--starting-token",
    "--max-items",
    "--page-size",
    "--working-dir",
    "--terragrunt-working-dir",
    "-chdir",
    "-var",
    "-var-file",
    "-state",
    "-out",
    "--format",
}

# Write intent -- used only to tailor the handover message.
AWS_READ_PREFIXES = (
    "get-",
    "list-",
    "describe-",
    "head-",
    "search-",
    "lookup-",
    "batch-get-",
)
AWS_READ_EXACT = {"ls", "scan", "query", "select"}
TF_WRITE_TOKENS = {
    "apply",
    "destroy",
    "import",
    "taint",
    "untaint",
    "refresh",
    "init",
    "force-unlock",
    "push",
    "rm",
    "mv",
    "replace-provider",
}


def _fail(message: str) -> None:
    """Block the tool call. Exit 2 tells Claude Code to refuse and show stderr."""
    sys.stderr.write(message)
    sys.exit(2)


# Tokens that precede the real binary and should be stepped over. Brackets are
# included so a subexpression like `(aws s3 rm ...)` still exposes its binary.
WRAPPERS = {
    "&",
    "sudo",
    "env",
    "command",
    "exec",
    "time",
    "call",
    "start",
    "then",
    "do",
    "(",
    ")",
    "{",
    "}",
}

# Separator TOKENS -- matched after tokenizing, never against the raw string.
# Splitting raw text on "|" mis-parses a separator inside a quoted argument, e.g.
# `grep -e "go-task\|task (optional)"`, which then looked like a `task` invocation.
SEPARATOR_TOKENS = {";", "|", "||", "&", "&&", "|&", "\n"}

ASSIGN_INLINE = re.compile(r"^\$?[\w:]+=")  # NAME=value  /  $env:NAME=value
ASSIGN_NAME = re.compile(r"^\$[\w:]+$")  # $var  /  $env:NAME  (then " = value")


def _tokens(command: str) -> list[str]:
    try:
        return shlex.split(command, posix=False)
    except ValueError:
        return command.split()


def _basename(token: str) -> str:
    return token.lower().strip("\"'").split("\\")[-1].split("/")[-1].removesuffix(".exe")


def _segments(command: str) -> list[list[str]]:
    """Tokenize once (quote-aware), then split on separator TOKENS.

    Quoting is why this cannot be a regex over the raw string: in
    `grep -e "go-task\\|task (optional)"` the `|` is data, not a command boundary.
    """
    lexer = shlex.shlex(command, posix=False, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = _tokens(command)

    segments: list[list[str]] = [[]]
    for token in tokens:
        if token in SEPARATOR_TOKENS:
            segments.append([])
        else:
            segments[-1].append(token)
    return segments


def _invocations(command: str) -> list[tuple[str, list[str]]]:
    """(binary, positional-args) for each command segment.

    Skips leading env/variable assignments and wrappers, so:
      `$env:AWS_PROFILE = 'genai-tf'; & terragrunt.exe plan --working-dir infra`
        -> [("terragrunt", ["plan"])]
    """
    found: list[tuple[str, list[str]]] = []
    for tokens in _segments(command):
        i = 0
        while i < len(tokens):
            token = tokens[i]
            if ASSIGN_INLINE.match(token):
                i += 1
                continue
            if ASSIGN_NAME.match(token) and i + 1 < len(tokens) and tokens[i + 1] == "=":
                i += 3  # skip `$name`, `=`, and the value
                continue
            if _basename(token) in WRAPPERS:
                i += 1
                continue
            found.append((_basename(token), _flagless(tokens[i + 1 :])))
            break
    return found


def _flagless(tokens: list[str]) -> list[str]:
    """Positional args only -- flags and the values they consume are dropped.

    `hcl fmt --check --working-dir infra` -> ["hcl", "fmt"]
    `--working-dir infra plan`            -> ["plan"]
    """
    out: list[str] = []
    skip = False
    for token in (t.lower() for t in tokens):
        if skip:
            skip = False
            continue
        if token.startswith("-"):
            if "=" not in token and token in VALUE_FLAGS:
                skip = True
            continue
        out.append(token)
    return out


def _mcp_server_profile(tool_name: str) -> str | None:
    """The AWS_PROFILE an MCP server is pinned to in .mcp.json, if any.

    An MCP `cli_command` with no --profile inherits the server's env, so we must
    resolve it rather than assume. Returns None when it cannot be determined --
    the caller then blocks, so a missing or retooled .mcp.json fails closed.
    """
    if not tool_name.startswith("mcp__"):
        return None
    server = tool_name.split("__")[1] if "__" in tool_name else ""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or "."
    try:
        config = json.loads((Path(root) / ".mcp.json").read_text(encoding="utf-8"))
        env = config["mcpServers"][server].get("env") or {}
    except (OSError, ValueError, KeyError, TypeError):
        return None
    profile = env.get("AWS_PROFILE")
    return profile.lower() if isinstance(profile, str) else None


def _mentioned_profiles(command: str) -> set[str]:
    found: set[str] = set()
    for pattern in PROFILE_PATTERNS:
        found.update(m.lower() for m in re.findall(pattern, command, re.IGNORECASE))
    return found


def _is_write(binary: str, positional: list[str]) -> bool:
    """Write intent -- used only to tailor the message, never to permit anything."""
    if binary in {"terraform", "terragrunt"}:
        return bool(set(positional) & TF_WRITE_TOKENS)
    if binary == "task":
        return bool(set(positional) & {"apply", "iam-baseline", "destroy"})
    if binary == "aws":
        if len(positional) < 2:
            return True  # cannot prove it reads
        operation = positional[1]
        if operation in AWS_READ_EXACT:
            return False
        return not operation.startswith(AWS_READ_PREFIXES)
    return False


def _touches_aws(binary: str, positional: list[str]) -> bool:
    """True when this invocation would contact AWS and thus needs an identity.

    Fails closed: an unrecognized subcommand is assumed to reach AWS.
    """
    if binary == "aws":
        return not (positional and positional[0] in AWS_LOCAL_ONLY)
    if binary in {"terraform", "terragrunt"}:
        # `fmt`, `hcl fmt`, `validate` never reach AWS.
        return not (positional and positional[0] in TF_LOCAL_ONLY)
    if binary == "task":
        return bool(positional) and not (set(positional) <= TASK_LOCAL_ONLY)
    return False


def main() -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        _fail("aws-admin-guard: could not parse hook input; blocking to stay safe.\n")
        return

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    command = next(
        (tool_input[k] for k in COMMAND_KEYS if isinstance(tool_input.get(k), str)),
        "",
    )
    if not command.strip():
        sys.exit(0)

    invocations = _invocations(command)
    aws_bound = [(b, p) for b, p in invocations if _touches_aws(b, p)]
    if not aws_bound:
        sys.exit(0)

    # Channel rule: reads of AWS state go through the MCP server, not the raw CLI.
    # This is not stylistic. `readonlyagent`'s grants are condition-gated on
    # `aws:CalledViaAWSMCP`, so a raw-CLI read returns "no identity-based policy
    # allows this action" -- which reads like a MISSING PERMISSION but is really a
    # WRONG CHANNEL. That misdiagnosis previously led to escalating to the admin
    # profile to "get past" it. Fail here, with the real reason, instead.
    if not tool_name.startswith("mcp__"):
        for binary, positional in aws_bound:
            if binary != "aws" or len(positional) < 2:
                continue
            if (positional[0], positional[1]) in CLI_READ_EXEMPT:
                continue
            if not _is_write(binary, positional):
                _fail(
                    "BLOCKED by aws-admin-guard: AWS reads must go through the MCP "
                    f"server, not the raw CLI.\n  Attempted: aws {positional[0]} "
                    f"{positional[1]}\n"
                    "\n"
                    "Use the mcp__aws-mcp__aws___call_aws tool instead.\n"
                    "Why this matters: readonlyagent's permissions are condition-gated on\n"
                    "aws:CalledViaAWSMCP, so this call would fail with 'no identity-based\n"
                    "policy allows...' -- which looks like a missing permission but is\n"
                    "really the wrong channel. Do NOT 'fix' it by switching profiles.\n"
                    "\n"
                    "The raw CLI is only for: writes as genai-tf (e.g. state-bucket ops),\n"
                    "credential-free subcommands, and sts get-caller-identity.\n"
                )

    profiles = _mentioned_profiles(command)
    if profiles and profiles <= ALLOWED_PROFILES:
        sys.exit(0)

    # An MCP call with no explicit --profile runs as the server's pinned env
    # profile. Allow it only if that pinned profile is itself allow-listed.
    if not profiles:
        pinned = _mcp_server_profile(tool_name)
        if pinned is not None and pinned in ALLOWED_PROFILES:
            sys.exit(0)

    allowed = ", ".join(sorted(ALLOWED_PROFILES))
    action = "WRITE to AWS" if any(_is_write(b, p) for b, p in aws_bound) else "AWS access"

    if profiles & ADMIN_PROFILES:
        _fail(
            f"BLOCKED by aws-admin-guard: attempted {action} as an ADMIN identity "
            f"({', '.join(sorted(profiles & ADMIN_PROFILES))}).\n"
            "\n"
            "*** THIS TASK REQUIRES ADMIN PRIVILEGES. ***\n"
            "The agent must NOT run it -- not even to read. Instead:\n"
            "  1. State plainly that the step needs admin privileges, and why.\n"
            "  2. Hand the user the exact command to run themselves.\n"
            "  3. Continue with verification steps that work under "
            f"{allowed}.\n"
        )

    if not profiles:
        _fail(
            f"BLOCKED by aws-admin-guard: attempted {action} with NO AWS profile pinned.\n"
            "\n"
            "There is deliberately no [default] profile, so ambient credentials do not\n"
            f"exist. Pin one of: {allowed}\n"
            "  e.g. $env:AWS_PROFILE = 'readonlyagent'   # reads\n"
            "       $env:AWS_PROFILE = 'genai-tf'        # provisioning\n"
        )

    _fail(
        f"BLOCKED by aws-admin-guard: attempted {action} as an unrecognized identity "
        f"({', '.join(sorted(profiles))}).\n"
        f"The agent may only use: {allowed}\n"
        "If this is the human's admin identity, hand them the exact command to run.\n"
    )


if __name__ == "__main__":
    main()
