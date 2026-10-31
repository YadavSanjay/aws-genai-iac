# `security/secrets` — secret containers

Creates `aws_secretsmanager_secret` and **never**
`aws_secretsmanager_secret_version`. That omission is the entire point.

Scope: LLM and data-source API keys, DB passwords — injected as environment
variables at container start.

## Why Terraform does not manage the values

A secret value placed in Terraform is a secret **in the state file, in
plaintext, forever** — every historical version of it, readable by anyone who
can read the state bucket, and printed in plan output along the way. Marking an
output `sensitive` hides it from the console; it does nothing to the state.

So Terraform manages the container, its encryption and its access policy. The
value is set out of band by a human or a rotation function.

**The practical consequence is intended:** an application cannot start until
someone sets the value. A missing secret should fail loudly at deploy time
rather than silently resolving to an empty string.

### Setting a value

```bash
aws secretsmanager put-secret-value \
  --secret-id genai-dev/macrorag/app \
  --secret-string '{"OPENAI_API_KEY":"...","ANTHROPIC_API_KEY":"..."}' \
  --region us-east-1 --profile <writer-profile>
```

The module's `set_value_commands` output prints these for the secrets it created.

## One secret per application, not per credential

Secrets Manager bills **$0.40 per secret per month regardless of size**. Five
separate API keys cost $2.00/month; one JSON object holding all five costs
$0.40. An application almost always needs all of its own credentials anyway, so
the finer granularity buys nothing.

Split only when different principals genuinely need different subsets.

The module enforces a **ceiling of 5 secrets** with a validation block. At
$0.40 each that is the difference between a known $2/month and a line item that
grows one forgotten secret at a time. Raising it should be a decision, not
drift.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `secrets` | map(object) | — | Name → `{ description, reader_role_arn_patterns? }`. Max 5 |
| `kms_key_arn` | string | — | Required; the AWS-managed key is not acceptable |
| `recovery_window_days` | number | `7` | 0 (immediate, unrecoverable) or 7–30 |
| `tags` | map(string) | `{}` | |

`reader_role_arn_patterns` is a **per-secret** field on each `secrets` entry
(default `[]`), not a component-wide list — see the resource-policy note below.

## Outputs

`secret_arns`, `secret_names`, `set_value_commands`.

## Security posture

### Our CMK, not `aws/secretsmanager`

The AWS-managed key cannot carry a scoped key policy and does not rotate on our
schedule. A secret encrypted under it sits outside every control the KMS module
establishes, so `kms_key_arn` is required with no default.

### The resource policy is a deny-with-exception, per secret

When a secret's `reader_role_arn_patterns` is set, the attached policy **denies**
`GetSecretValue` to any principal whose ARN does not match — rather than
allowing the ones that do.

That direction matters. A bare allow can be widened by any additional allow
elsewhere in the account; an explicit deny cannot. So reading a secret requires
*both* an IAM grant and membership of the reader set, and an over-broad IAM
policy somewhere else cannot on its own expose the values.

The reader set is **per secret**, not one list across the component. When the
module holds several applications' secrets, each gets only its own owner's
reader set — otherwise one application's reader patterns would be attached to
another's secret, denying the real owner access to its own credential. A secret
that declares no patterns gets no resource policy (IAM-only).

`block_public_policy` is on, which also stops a policy that would lock out
every principal.

### `recovery_window_days = 0` is available but dangerous

Immediate deletion is unrecoverable. It exists because a 7-day pending deletion
blocks recreating a secret of the same name, which makes repeated dev teardown
painful. **Never use it in prod** — it turns a typo into permanent loss.

### No rotation configured

There is no rotation Lambda. Rotation for a third-party API key is not a
generic operation — it means calling that vendor's key-rotation API, which
differs per vendor and does not exist for some. Configuring rotation without a
working rotator produces a secret that reports itself as rotating while doing
nothing, which is worse than no rotation at all.

Rotation belongs with the specific credential, added deliberately.

## Cost profile

| Line item | Rate |
|---|---|
| Secret storage | **$0.40 / secret / month** |
| API calls | $0.05 / 10,000 |

**The per-secret charge dominates, and it is per secret, not per byte.** That is
what drives the one-JSON-object-per-application guidance above.

API call cost is negligible if applications fetch at startup and cache. It stops
being negligible if something fetches per request — 10 requests/second is ~26
million calls a month, roughly $130. Cache the value; never call Secrets Manager
on a hot path.

Current usage: 1 secret ≈ **$0.40/month**.

## Verification

`tests/integration/test_secrets.py` asserts the container's encryption key,
recovery window, tags and resource policy. It **skips with an explicit reason**
when no value has been set yet, since that is an out-of-band human step — the
skip reads as "unverified", not "passing".
