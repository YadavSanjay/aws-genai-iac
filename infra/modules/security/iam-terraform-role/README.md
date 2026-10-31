# security/iam-terraform-role

Creates the **Terraform execution role** (`<prefix>-terraform-exec`) for the
aws-genai-iac control plane, the customer-managed policies attached to it, and
the **permissions boundary** (`<prefix>-app-boundary`) that every app role
Terraform later creates must carry.

The role — not a long-lived IAM user — is the thing that holds the power.
Humans (ideally via IAM Identity Center) or CI assume it for short-lived
credentials. See `docs/runbooks/terraform-execution-role.md` for the operational
flow (who bootstraps the backend, the KMS caveat, how to assume the role).

## What it creates

| Resource | Purpose |
|---|---|
| `aws_iam_role.exec` (`<prefix>-terraform-exec`) | Assumed to run `terragrunt`. Trust = `trusted_principal_arns` (or account root); MFA optional via `require_mfa`. |
| `<prefix>-tf-compute-net` | ec2 / elb / autoscaling / ecs / ecr (region-locked) + route53 / acm. |
| `<prefix>-tf-data-ops` | rds, s3, backup, dynamodb, sqs, secretsmanager, kms, logs, cloudwatch, sns, scheduler, events, budgets, ce, cur. |
| `<prefix>-tf-iam` | Create/manage the `<prefix>-*` app roles — **only with the boundary attached** — plus scoped `PassRole`. |
| `<prefix>-tf-state` | Read/write remote state objects + their S3-native `.tflock` locks. No backend-creation rights. |
| `<prefix>-tf-guardrail` | Explicit denies: org/account/IAM-user surface + exec-role self-modification + boundary removal. |
| `<prefix>-app-boundary` | Permissions boundary — the ceiling for every Terraform-created app role. |
| `tfuser` (optional) | Dedicated Terraform IAM user when `create_terraform_user = true`. `assume-role` mode (default) = doorway only; `direct-attach` = scoped policies on the user. Access keys minted out-of-band (`aws iam create-access-key`), never in state. |

## Escalation containment

`<prefix>-tf-iam` can create app roles, but the `CreateRoleWithBoundary`
statement only permits it when `iam:PermissionsBoundary` equals
`<prefix>-app-boundary`. That boundary hard-denies `iam:*`, `organizations:*`,
`account:*`, and `sts:AssumeRole`, so no role Terraform mints can be more
powerful than the exec role itself. The guardrail additionally stops the exec
role from editing its own policies or stripping a boundary.

## Usage

Applied **once by an admin/bootstrap identity** (chicken-and-egg: the exec role
does not exist yet). Wired via `environments/global/iam-baseline` — this block
mirrors that component's inputs. For the operational flow (bootstrap order,
minting `tfuser` keys, the `genai-tf` profile, the KMS caveat) see
`docs/runbooks/terraform-execution-role.md`.

```hcl
module "tf_role" {
  source                = "../../modules/security/iam-terraform-role"
  name_prefix           = "genai"
  account_id            = "<account id>"    # real value from the gitignored account.local.hcl
  region                = "us-east-1"
  state_bucket          = "aws-genai-iac-tfstate"
  create_terraform_user = true              # dedicated tfuser
  user_access_mode      = "assume-role"     # tfuser only assumes the role
  require_mfa           = false             # tfuser is programmatic
}
```

Then feed `app_boundary_arn` into the app-role modules as their
`permissions_boundary`, and set the exec role in the provider:

```hcl
provider "aws" {
  assume_role { role_arn = module.tf_role.exec_role_arn }
}
```

## Notes

- `s3:*` / `ec2:*` / `kms:*` read broad; real containment is the region lock,
  the boundary, and the deny guardrail — not action enumeration.
- Managed AI services (bedrock/sagemaker/eks/opensearch) are intentionally
  absent, matching `docs/design/aws-service-consolidation.md`.
- If the state bucket moves to a **customer-managed KMS key**, add the exec role
  to that key policy (`kms:Decrypt`, `kms:GenerateDataKey`) — see the runbook.
