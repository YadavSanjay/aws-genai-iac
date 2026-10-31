# Runbook — Terraform execution role

How the aws-genai-iac control plane authenticates to AWS: **an admin bootstraps
the backend once, then all Terraform runs as a dedicated execution role** that
nobody uses as a daily identity. Implemented by
`infra/modules/security/iam-terraform-role` (see its README for the full
resource/policy table and escalation model), wired via
`infra/environments/global/iam-baseline`.

> **Status — reconciled 2026-07-22:** the S3 state backend and `global/iam-baseline`
> are applied — `genai-terraform-exec` + the five scoped policies + `genai-app-boundary`
> + `tfuser` (assume-role mode, `require_mfa = false`). Locking is S3-native; the former
> DynamoDB lock table has been deleted. Day-to-day Terraform runs via the `genai-tf` AWS
> profile (see Steady state). The full `dev` estate has since been provisioned *by* this
> role — see the live-component table on the
> [status page](../status.md). This runbook covers only the
> identity/bootstrap model, which is unchanged.
>
> Substitute your real account id — kept only in the gitignored
> `infra/account.local.hcl` — wherever `<acct>` appears below. Never commit it.

## Identity model

```
genai-terraform-exec   (ROLE)  ← all the power: 5 managed policies + boundary
        ▲ sts:AssumeRole (short-lived creds; MFA optional via require_mfa)
        │
  a thin tfuser (AssumeRole only)   [IAM Identity Center: possible future option]
```

Power lives on the **role**, never on a long-lived user with static keys.

- **IAM Identity Center (SSO) — NOT IN USE TODAY.** If adopted later, a permission
  set would grant `sts:AssumeRole` onto `genai-terraform-exec`, giving short-lived
  creds with no access keys on disk. There is currently no Identity Center in this
  account; the real identities are `<admin-profile>` (admin), `tfuser`, and `readonlyagent`.
- **Acceptable alternative — a thin `tfuser`.** Its *only* permission is
  `sts:AssumeRole` onto the exec role. The dangerous surface stays on the role;
  `tfuser` is just a doorway you can MFA-gate and rotate independently. The
  module creates this for you (`create_terraform_user = true`, default
  `user_access_mode = "assume-role"`) and auto-adds it to the role trust.

The point is to keep AdministratorAccess (your personal admin user) out of
Terraform. Both `user_access_mode` values achieve that; they differ only in
credential safety:

| Mode | Where power lives | tfuser credential | Trade-off |
|---|---|---|---|
| `assume-role` (default) | on the exec **role** | short-lived STS session | keys alone can't act; expire; MFA-gateable; revoke = disable user |
| `direct-attach` | on **tfuser** directly | long-lived access keys | simplest `--profile tfuser` flow; leaked keys wield full scoped power |

Prefer `assume-role`. Use `direct-attach` only if role-assumption friction
(MFA prompts, profile juggling) outweighs the standing-key risk.

## One-time bootstrap (run by an admin)

The exec role can't create itself, so an admin/bootstrap identity does the first
two steps.

1. **Create the state backend.** Run `scripts/bootstrap-backend.sh` as the admin.
   It creates the `aws-genai-iac-tfstate` bucket. These verbs (`s3:CreateBucket`,
   `PutBucketVersioning/Encryption/PublicAccessBlock`) are intentionally **not**
   in the exec role.

   State locking is **S3-native** (`use_lockfile = true` in `infra/root.hcl`) —
   a conditional-write `<key>.tflock` object beside each state file. There is no
   DynamoDB lock table; the exec role's existing `s3:PutObject`/`s3:DeleteObject`
   on the bucket covers the lock, and the app boundary's `s3:*` deny on the same
   bucket keeps app roles away from state and locks alike.

   **Backend conventions worth knowing before you add a component:**
   - The root config is **`infra/root.hcl`**, not `terragrunt.hcl` — a *root* file
     named `terragrunt.hcl` is a deprecated Terragrunt anti-pattern. Components
     include it as `include "root" { path = find_in_parent_folders("root.hcl") }`;
     the bare no-arg `find_in_parent_folders()` form will not find it.
   - State keys are normalized with `replace(path_relative_to_include(), "\\", "/")`.
     On Windows the un-normalized form emits **literal backslashes into the S3 key**,
     so a POSIX shell or CI runner computes a different key, misses the existing
     state, and tries to recreate everything.

2. **Apply `global/iam-baseline` as the admin** — creates `genai-terraform-exec`,
   its five managed policies, the `genai-app-boundary`, and (with
   `create_terraform_user = true`) the `tfuser`. This component has **no**
   `assume_role` provider block (the role doesn't exist yet).

   ```bash
   cd infra/environments/global/iam-baseline
   terragrunt apply           # as your AdministratorAccess identity
   ```

   The exec role's guardrail denies `iam:*User*`, so `tfuser` can only ever be
   created/modified by an admin here — never by Terraform running as the exec role.

3. **Mint `tfuser` access keys** (keys are deliberately not in Terraform state):

   ```bash
   aws iam create-access-key --user-name tfuser      # as the admin
   ```

   Store them in an `aws` profile (e.g. `[tfuser]` in `~/.aws/credentials`).

4. **(Optional) pin the trust.** In `assume-role` mode the module already added
   `tfuser` to the role trust. To also let an SSO/admin identity assume the role,
   add its ARN in `infra/account.local.hcl` and re-apply:

   ```hcl
   locals {
     account_id             = "<real 12-digit id>"
     terraform_trusted_arns = ["arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<permission-set-role>"]
   }
   ```

   (Empty → account root + MFA, plus `tfuser`.)

### MFA note for `tfuser` + assume-role

The component sets `require_mfa = false` — `tfuser` is programmatic, so its access
keys are the only factor and role assumption is non-interactive. If you later
want an MFA gate, set `require_mfa = true` in the component inputs, register an
MFA device on `tfuser`, and add `mfa_serial` to the `[tfuser]` profile so the CLI
prompts for a code when assuming the role.

## Steady state — everything else runs AS the exec role

The cleanest way to run `tfuser → assume genai-terraform-exec` uniformly across
aws-cli, terraform, and terragrunt is a **named AWS profile** — the SDK does the
assumption, so no terragrunt flags or version-specific syntax are involved.

`~/.aws/credentials` (from step 3):

```ini
[tfuser]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...
```

`~/.aws/config`:

```ini
[profile genai-tf]
role_arn       = arn:aws:iam::<acct>:role/genai-terraform-exec
source_profile = tfuser
region         = us-east-1
```

Then every day-to-day command runs as the exec role just by selecting the profile:

```powershell
$env:AWS_PROFILE = "genai-tf"
task whoami                 # => .../genai-terraform-exec/... confirms the assumption
task plan  ENV=dev          # terragrunt run --all -- plan, as the exec role
task apply ENV=dev
```

go-task is installed on this machine; CLAUDE.md → *Local toolchain* maps each target
to its underlying command if you need to run it directly. The
`plan`/`apply`/`iam-baseline` targets self-guard on the resolved STS ARN, so a wrong
`AWS_PROFILE` is refused rather than silently applied — note that direct `terragrunt`
calls bypass those guards.

> **Two identities, one machine.** This `genai-tf` (provisioning) profile coexists
> with the read-only `readonlyagent` profile that Claude Code's AWS MCP uses. Both
> are backed by **static keys** and pinned to their own profile, so neither disturbs
> the other and a browser sign-in can't hijack either. Full explanation:
> `docs/runbooks/agent-toolkit-setup.md` → *Two identities, two profiles*.

Alternatives, if you prefer not to use a profile:

- Set `TG_IAM_ASSUME_ROLE=arn:aws:iam::<acct>:role/genai-terraform-exec`
  (Terragrunt v1.x env var; the flag form is `--iam-assume-role`), or
- add `assume_role { role_arn = <exec arn> }` to the root provider generation —
  but exclude `global/iam-baseline`, which must run as the admin (the role does
  not exist during its first apply).

App-role modules (`security/iam`) must attach the boundary:
`permissions_boundary = <genai-app-boundary arn>` — otherwise the exec role's
`CreateRoleWithBoundary` statement denies the create. (Why this contains
privilege escalation: see *Escalation containment* in the module README,
`infra/modules/security/iam-terraform-role/README.md`.)

## Does the bootstrap creator gate the exec role's access? No.

S3 access is **identity-based** — decided by the *caller's* attached policies, not
by who created the bucket. The bootstrap script attaches no bucket policy, and it's
a single account (bucket owner = the account), so the exec role reads/writes state
purely via its own `genai-tf-state` policy. Admin creating the backend changes
nothing for the exec role. The same applies to the `.tflock` lock objects — they
live in that bucket and are covered by the same statement.

### The one caveat — KMS

`scripts/bootstrap-backend.sh` encrypts the state bucket with `SSEAlgorithm:
aws:kms` and **no** `KMSMasterKeyID`, i.e. the AWS-managed `aws/s3` key. Access
to that key is automatic for same-account principals with S3 access — nothing to
configure.

**If you switch the state bucket to a customer-managed KMS key**, the exec role
is *not* granted automatically. Add it to that key policy, or state reads fail
with `AccessDenied` on the key:

```json
{ "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::<acct>:role/genai-terraform-exec" },
  "Action": ["kms:Decrypt","kms:GenerateDataKey"],
  "Resource": "*" }
```

## Scope summary

The exec role covers exactly the compute/network/data/ops/edge surface the four
subsystems use, plus boundary-constrained IAM-role creation, minus an explicit
deny on the org/account/IAM-user surface. Managed AI services
(bedrock/sagemaker/eks/opensearch) are absent by design.

For the per-policy breakdown see the module README's *What it creates* table
(`infra/modules/security/iam-terraform-role/README.md`); for why the AI services
are out of scope see `docs/design/aws-service-consolidation.md`.
