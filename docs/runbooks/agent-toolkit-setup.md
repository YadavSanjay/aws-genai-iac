# Runbook: Agent Toolkit for AWS — read-only live access

Reproducible setup for connecting Claude Code to this AWS account via the **Agent
Toolkit for AWS** (the managed AWS MCP Server behind `mcp-proxy-for-aws`), scoped
**read-only** so the agent can inspect and troubleshoot live resources without
ever mutating infrastructure.

## Governing principle (read this first)

**Terraform/Terragrunt is the only thing that provisions or changes AWS resources
in this project.** The Agent Toolkit is *not* a deterministic IaC engine — its
provisioning is imperative and would create **drift** against Terraform state. So
we use it in one lane only:

- ✅ Advisory — up-to-date service knowledge, best-practice configs, help authoring Terraform.
- ✅ Read-only troubleshooting — describe live resources, read CloudWatch logs/metrics, CloudFormation status.
- ❌ Never create/modify/delete resources out-of-band.

### How read-only is enforced

On the **general** AWS MCP Server the only live executors are `aws___call_aws`
and `aws___run_script`, and **each can read *or* write** — so the read/write line
is drawn by **IAM**, not by hiding tools:

1. **Read-only IAM identity (primary guardrail — Step 1)** — the agent's SigV4
   credentials resolve to a principal allowed only `Describe*/Get*/List*`, gated
   by the AWS MCP context key. AWS itself denies any mutating call.
2. **Explicit `Deny` backstop (Step 1)** — a `Deny` whose `NotAction` mirrors the
   read allow-list blocks anything that isn't an allow-listed read, so widening
   the `Allow` later can't silently grant writes.
3. **Client-side deny on `aws___run_script` (Step 4)** — drops the arbitrary-Python
   executor at the Claude Code layer to shrink attack surface, leaving
   `aws___call_aws` available for reads.

> **Do not pass the proxy `--read-only` flag here, and do not deny `call_aws`.**
> `--read-only` drops every tool not annotated `readOnlyHint=true`; on the general
> AWS MCP Server that removes `call_aws` *and* `run_script` entirely, leaving only
> doc/knowledge tools and **no live-resource access at all**. Denying `call_aws`
> client-side has the same effect. (Service-specific servers — eks-mcp, ecs-mcp —
> ship granular per-operation tools each annotated `readOnlyHint`, so `--read-only`
> is meaningful there, but not on this one.)

## Prerequisites

| Item | Requirement |
|---|---|
| AWS account | The project's single target account — `account_id` lives ONLY in the **gitignored** `infra/account.local.hcl`, never in a committed file. |
| Region | `us-east-1` (`infra/account.hcl`, committed — no secrets). |
| AWS CLI | v2.32+, on PATH. |
| `uv` / `uvx` | Runs the MCP proxy. On PATH. |
| Client | Claude Code (this project). |

> After installing/relocating `uv`, **fully restart Claude Code** (not just
> `/reload-plugins`) so its process inherits the updated PATH — otherwise a bare
> `uvx` launch fails and `aws-mcp` shows **Failed** in `/mcp`. Pre-warm the proxy
> once so the first connection doesn't time out: `uvx mcp-proxy-for-aws@1.6.3 --help`.

## Step 1 — Create the read-only agent IAM identity

Create a dedicated principal for the agent (do not reuse an admin identity) and
attach the policy below: the **`Allow`** is gated to calls made through the AWS
MCP Server; the **`Deny`** backstops anything that isn't an allow-listed read.

### Getting the condition key right (the most common failure)

AWS exposes **two different** MCP context keys — the wrong operator/type silently
drops the `Allow`, so every call is denied:

| Key | Type | Correct usage |
|---|---|---|
| `aws:ViaAWSMCPService` | **Boolean** | `"Bool": { "aws:ViaAWSMCPService": "true" }` — true for *any* AWS-managed MCP server. |
| `aws:CalledViaAWSMCP` | **String** (service principal) | `"StringEquals": { "aws:CalledViaAWSMCP": "aws-mcp.amazonaws.com" }` — pins to the general AWS MCP Server. |

`"Bool": { "aws:CalledViaAWSMCP": "true" }` is the **wrong** combination (a `Bool`
operator on a `String` key whose value is a principal name, never `"true"`) — it
never matches, so the grant never applies and every call is denied.

> **Template — validate against your security baseline before applying.** Keep the
> `Allow` describe/get/list-only. **When you add a read action, add it to *both*
> the `Allow.Action` and the `Deny.NotAction` lists** — otherwise the backstop
> denies the very read you just granted.

The policy document is version-controlled at
**[`policies/iam/readonlyagent_mcp.json`](../../policies/iam/readonlyagent_mcp.json)** —
that file is the single source of truth. It is *not* Terraform-managed: the exec
role's guardrail denies `iam:*User*`, so this policy is applied by an admin (see
[Updating the policy](#updating-the-policy) below).

It has two mirrored statements:

| Statement | Effect | Purpose |
|---|---|---|
| `ProjectReadOnlyInspectViaMCP` | `Allow` | Read allow-list, gated on `StringEquals aws:CalledViaAWSMCP = aws-mcp.amazonaws.com` |
| `DenyAnythingNotReadOnlyViaMCP` | `Deny` | `NotAction` = the same list, gated on `Bool aws:ViaAWSMCPService = true` |

### Updating the policy

**The two action lists must stay byte-identical.** Adding a read to `Allow.Action`
alone leaves `Deny.NotAction` still blocking it, and the symptom is a confusing
*"explicit deny in an identity-based policy"* on a permission you just granted.

Edit the JSON, then as an **admin** identity:

```powershell
aws iam create-policy-version `
  --policy-arn arn:aws:iam::<acct>:policy/readonlyagent_mcp `
  --policy-document file://policies/iam/readonlyagent_mcp.json `
  --set-as-default `
  --profile <admin-profile>
```

IAM keeps at most **5 versions** — prune with `aws iam delete-policy-version`
if `list-policy-versions` shows five.

Notes:
- The `Allow` is pinned to the general AWS MCP Server via
  `StringEquals aws:CalledViaAWSMCP = aws-mcp.amazonaws.com`. If it doesn't take
  effect, confirm the exact principal value in CloudTrail (request-context key
  `aws:CalledViaAWSMCP`) or fall back to `"Bool": { "aws:ViaAWSMCPService": "true" }`.
- The `Deny` uses `NotAction` = the read allow-list, gated by
  `aws:ViaAWSMCPService`, so **any non-read action via any AWS-managed MCP server
  is denied** even if the `Allow` is later widened. Keep the two lists in sync.
- `secretsmanager` is `Describe`/`List`/`GetResourcePolicy` only — **not**
  `GetSecretValue`; `s3` is bucket-metadata/list only — **not** `GetObject`. Both
  sensitive reads sit outside `NotAction`, so the `Deny` blocks them too.
- Using OAuth sign-in instead of SigV4? Also attach the managed policy
  `arn:aws:iam::aws:policy/AWSMCPSignInOAuthAccessPolicy`. The SigV4 path below
  does not need it.

## Step 2 — Authenticate

The proxy signs requests with whatever `AWS_PROFILE = readonlyagent` resolves
(pinned in Step 3). **This project uses static access keys for that profile** — the
durable, drift-proof choice; see [Two identities, two profiles](#two-identities-two-profiles)
for why.

**Static keys (recommended).** As an admin, mint a key for the read-only agent
(one-time — the secret is shown once):

```powershell
aws iam create-access-key --user-name readonlyagent --profile <admin-profile>
```

Store it in `~/.aws/credentials`:

```ini
[readonlyagent]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...
```

and make `~/.aws/config` resolve those keys (note: **no** `login_session`, **no**
`source_profile` — just the region):

```ini
[profile readonlyagent]
region = us-east-1
```

**Confirm through the MCP server, not the CLI.** Reconnect `/mcp` and have the
agent run a read (e.g. list regions). A raw `aws --profile readonlyagent ...` call
will be **denied**: every grant in the Step-1 policy is conditioned on
`aws:CalledViaAWSMCP`, which is only present inside the AWS-MCP request context.
The agent's `aws_admin_guard.py` hook blocks raw-CLI AWS reads for the same reason.

> `aws sts get-caller-identity --profile readonlyagent` is the one exception that
> *does* work from the CLI — it requires no IAM permission at all. Useful to prove
> the profile resolves; it proves nothing about the MCP grants.

**There is no `aws login` alternative for `readonlyagent`.** Its permissions only
function through the AWS MCP server, so a browser-session identity cannot serve it.
Static keys pinned via `.mcp.json` are the only supported path. (`aws login` is
`<admin-profile>`'s admin flow — unrelated to this profile, and off-limits to the agent.)

## Step 3 — Add the AWS MCP Server to Claude Code

Add the authenticated server via the proxy, pinned to `us-east-1`, using the
**absolute** `uvx` path (more robust than a bare `uvx`, which depends on PATH).
**No `--read-only`** — read-only is enforced by the Step-1 IAM policy. **Pin the
credential profile with `env.AWS_PROFILE = "readonlyagent"`** so the proxy always
resolves the read-only identity regardless of any browser session active on the
machine (see [Two identities, two profiles](#two-identities-two-profiles)):

```jsonc
{
  "mcpServers": {
    "aws-mcp": {
      "command": "D:\\Tools\\UV\\uvx.exe",
      "transport": "stdio",
      "timeout": 100000,
      "args": [
        "mcp-proxy-for-aws==1.6.3",
        "https://aws-mcp.us-east-1.api.aws/mcp",
        "--region", "us-east-1",
        "--metadata", "AWS_REGION=us-east-1"
      ],
      "env": {
        "AWS_PROFILE": "readonlyagent"
      }
    }
  }
}
```

This project ships that entry as `.mcp.json.example`. Copy it to `.mcp.json`
(git-ignored, because it can carry a machine-specific path). After editing it, **Reconnect** the server in `/mcp` (or
restart Claude Code) so the proxy process picks up the new `AWS_PROFILE`.

## Two identities, two profiles

Live work uses two AWS identities, and the golden rule that keeps them from
stepping on each other is: **give each its own named profile backed by static
access keys, pin every tool to its profile, and never rely on `[default]`.**

| Consumer | Profile | Credentials | How it's selected |
|---|---|---|---|
| Claude Code live reads (AWS MCP) | `readonlyagent` | static `[readonlyagent]` keys in `~/.aws/credentials` | `env.AWS_PROFILE` in `.mcp.json` (Step 3) |
| Terraform / Terragrunt provisioning | `genai-tf` → assumes `genai-terraform-exec` | static `[tfuser]` keys in `~/.aws/credentials` | `AWS_PROFILE=genai-tf` in the terminal |

### The problem we hit, and the fix (historical — resolved 2026-07-19)

`readonlyagent` **originally** signed in with `aws login` (a browser flow). That
browser session was tied to the `[default]` profile, and `aws login` keeps
essentially **one active session at a time**. So when we signed in as `<admin-profile>` to run
a Terraform apply, it repointed `[default]` and knocked the read-only agent offline —
the agent either picked up `<admin-profile>` or its connection dropped outright.

**The fix: put `readonlyagent` on its own static access keys** (exactly like
`tfuser`) and pin the MCP to that profile. Static keys are read straight from
`~/.aws/credentials` — they never touch the browser or `aws login`. Verified at the
time: the MCP returned `readonlyagent` while `[default]` still resolved to `<admin-profile>`.

`[default]` was subsequently **removed altogether** (see the notes below), so that
failure mode no longer has a mechanism. Both agent lanes use static keys and share
nothing.

Provisioning from the command line (unchanged from the exec-role runbook):

```powershell
$env:AWS_PROFILE = "genai-tf"     # tfuser -> assume genai-terraform-exec
task whoami                        # => .../genai-terraform-exec/... 
task plan ENV=dev; task apply ENV=dev
```

Notes:

- **Reconnect the MCP** (`/mcp` → Reconnect, or restart Claude Code) after any
  change to `.mcp.json` or the `readonlyagent` credentials, so the proxy re-reads them.
- **`[default]` has been REMOVED** (2026-07-19; backup at `~/.aws/config.bak-*`). It
  resolved to `<admin-profile>`, so an un-pinned command silently ran as admin. Now an
  un-pinned call fails closed with `NoCredentials`.

  **Do not recreate it — not even pointing at `readonlyagent`.** An earlier note here
  suggested that as a safe fallback; we rejected it. A silent read-only fallback
  masks a forgotten pin, and the whole point is that forgetting is *loud*. Every
  consumer pins its profile explicitly.

  This also means an active `<admin-profile>` browser session can never be picked up
  ambiently by an unrelated command — sign in as whoever you like.
- **Don't leave `AWS_PROFILE=<admin-profile>` set** after an admin task (e.g. `iam-baseline`);
  reset to `genai-tf` or close the shell.
- **Claude Code may not use `<admin-profile>` at all** — not even for reads. Two `PreToolUse`
  hooks enforce this (see the repo `CLAUDE.md` → *AWS credential rule*):
  - `scripts/aws_admin_guard.py` — an **allow-list**: only `readonlyagent`,
    `genai-tf`, `tfuser`. It also blocks **unpinned** commands (no `[default]` to
    fall back on) and **raw-CLI AWS reads**, which must go through the MCP server.
    It covers Bash, PowerShell, and the MCP tool itself, so a `--profile <admin-profile>`
    inside an MCP `cli_command` cannot override the server's pinned profile.
  - `scripts/protected_paths_guard.py` — makes the guards, their tests,
    `.claude/settings.json`, `.mcp.json`, and `~/.aws/*` **read-only to the agent**,
    so it cannot weaken its own controls.

  The unit tests in `tests/unit/` cover all three guards
  (`aws_admin_guard`, `protected_paths_guard`, `shell_tool_guard`) plus the
  read-only MCP IAM policy. The wiring lives in the **gitignored**
  `.claude/settings.json` — a fresh clone gets the scripts but not the hooks, so
  verify the wiring is live rather than assuming it. Admin steps are described and
  handed to you to run.
- Both `readonlyagent` and `tfuser` keys are static and long-lived. The agent keys
  are read-only *and* only work through the AWS-MCP service (Step 1 policy), so their
  blast radius is minimal; `tfuser`'s standing risk was accepted deliberately. Rotate
  either if that posture changes.

### If you use the `aws-core` plugin bundle

The `aws-core` plugin (`/plugin install aws-core@claude-plugins-official`) ships
its **own** `aws-mcp` server that runs `--skip-auth` — **unauthenticated**, so it
can search docs/skills but cannot touch the account, and it is not the
live-troubleshooting setup. For live read-only access, **disable the bundled
`aws-mcp`** (`/mcp` → Disable) and use the authenticated entry above; running both
creates duplicate `aws___*` tools. Either way, the Step-1 IAM policy is what keeps
access read-only.

## Step 4 — Client-side deny on `run_script` (defense-in-depth)

`aws___call_aws` and `aws___run_script` are **both** read executors, so we deny
only `run_script` (the arbitrary-Python executor) — never `call_aws`, which is the
only tool that can run a `Describe*/Get*/List*` call. Applied in the portable user
config (the user-level `settings.json`, under `CLAUDE_CONFIG_DIR` or `~/.claude`), for both
the standalone and plugin server names.

> **Two settings files, deliberately.** This `run_script` deny is a cross-project
> rule, so it lives in the user-level `settings.json`. The AWS-profile
> guards are project-specific and live in this repo's
> `.claude/settings.json`. If you are looking for a hook and cannot find it, check
> both.

```jsonc
{
  "permissions": {
    "deny": [
      "mcp__aws-mcp__aws___run_script",
      "mcp__plugin_aws-core_aws-mcp__aws___run_script"
    ]
  }
}
```

## Step 5 — Verify

1. Start a new Claude Code conversation.
2. Ask *"What AWS Regions are available?"* — a region list confirms the server is connected.
3. Confirm tools: `aws___call_aws` and the knowledge tools (`aws___search_documentation`,
   `aws___retrieve_skill`) are loaded, and `aws___run_script` is **absent** (Step 4).
4. Confirm the guardrail: *describe* a resource (works via `call_aws`) and try to
   *create/modify/delete* one (IAM denies it — the `Deny` backstop plus the absent `Allow`).

## Troubleshooting

- **MCP panel shows `MCP error -32602: Invalid request parameters` / server
  `Failed`.** The proxy could not resolve credentials for `[readonlyagent]`. Check,
  in order: the `[readonlyagent]` section still exists in `~/.aws/credentials`;
  `env.AWS_PROFILE` is still `"readonlyagent"` in `.mcp.json`; and the access key is
  still active. Then **Reconnect** in `/mcp` (or restart Claude Code).

  Because `[default]` has been removed, a missing or renamed profile fails closed
  with `NoCredentials` — it will never silently fall back to another identity.

  > Checking whether the key is active (`aws iam list-access-keys --user-name
  > readonlyagent`) needs admin and must be run by the human — the agent is barred
  > from the `<admin-profile>` profile.

  > **Historical:** this symptom used to mean an expired `aws login` browser
  > session, back when `readonlyagent` used that flow. It no longer does — it uses
  > static keys. Do **not** run `aws login` to "fix" the MCP server; that is the
  > admin identity and it cannot affect this profile.
- **`aws-mcp` shows `Failed` right after a `uv` install or move.** PATH wasn't
  inherited — fully restart Claude Code (see [Prerequisites](#prerequisites)).
- **Empty `describe-*` results may mean "scheduled down", not "not built".** The
  full `dev` estate is deployed over the project VPC `10.10.0.0/16` (see the
  live-component table on the [status page](../status.md)),
  but the scheduled workloads (NAT instance, app EC2, RagInference) are stopped or
  scaled to zero off-hours by design — so an empty result during off-hours is
  expected. Query during the daily up-window, or check the schedules, before
  concluding a resource is missing.

## Sources
- Product: https://aws.amazon.com/products/developer-tools/agent-toolkit-for-aws/
- Getting started: https://docs.aws.amazon.com/agent-toolkit/latest/userguide/quick-start.html
- AWS MCP Server setup: https://docs.aws.amazon.com/agent-toolkit/latest/userguide/getting-started-aws-mcp-server.html
- IAM for managed AWS MCP servers: https://aws.amazon.com/blogs/security/understanding-iam-for-managed-aws-mcp-servers/
- MCP Proxy for AWS: https://github.com/aws/mcp-proxy-for-aws
