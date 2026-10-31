# `security/kms` — shared customer-managed key

One symmetric CMK per environment, with automatic rotation, a stable alias, and
a key policy that confines data-plane use to AWS services acting for callers in
this account.

## Why one key per environment, not one per data store

Per-store keys give finer blast-radius isolation, but each carries a fixed
**$1/month** charge and that isolation only pays off when different stores have
genuinely different access populations. At dev scale it is paying for separation
nobody enforces. Splitting later is a key-policy change plus a re-encrypt, not a
redesign — so this is a reversible decision, taken cheaply now.

`prod` should reconsider: a key per data classification (customer data vs
operational logs) is worth $1/month once there is data worth separating.

## Resources

| Resource | Purpose |
|---|---|
| `aws_kms_key.this` | Symmetric CMK, rotation on |
| `aws_kms_alias.this` | `alias/<name_prefix>-<alias>` — the stable handle |

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `account_id` | string | — | 12 digits, validated |
| `region` | string | — | Builds `kms:ViaService` principals |
| `alias` | string | `primary` | Suffix only; no `alias/` prefix |
| `description` | string | see variables | Console description |
| `deletion_window_days` | number | `7` | 7–30. **The only recovery window** |
| `enable_rotation` | bool | `true` | Keep true |
| `rotation_period_days` | number | `365` | 90–2560 |
| `via_services` | list(string) | 12 services | Every entry widens the data plane |
| `allow_cloudwatch_logs` | bool | `true` | Needed for encrypted log groups |
| `tags` | map(string) | `{}` | Merged onto all resources |

## Outputs

`key_id`, `key_arn`, `alias_name`, `alias_arn`.

**Reference `alias_name` downstream, not `key_id`** — a key replacement then
does not require editing every consumer.

## Security posture

- **`kms:ViaService` is the control that matters.** No principal can call
  `Decrypt` directly against this key. Only the listed AWS services may, and
  only while acting for a caller in this account (`kms:CallerAccount`). A leaked
  role credential therefore cannot bulk-decrypt ciphertext outside the service
  path that produced it.
- **Rotation on**, 365-day period. Old material is retained so existing
  ciphertext stays readable.
- **CloudWatch Logs is scoped by encryption context** to log groups in this
  account and region, so the grant cannot be turned on log groups elsewhere.
- **Service grants** (`kms:CreateGrant`) are gated on
  `kms:GrantIsForAWSResource`, so only AWS services creating grants for their
  own resources qualify — not arbitrary principals.

### Deliberate relaxation: the root delegation

`EnableIAMPolicyDelegation` grants `kms:*` to the account root. This looks like
the wildcard the provisioning principles forbid, and it is retained on purpose.

**Reason.** A KMS key policy is *authoritative*: unlike almost every other AWS
resource, IAM permissions alone do not grant access to a key. Omit the root
delegation and the key becomes permanently unmanageable the moment the
administering principal is deleted — AWS provides no recovery path, and the
data encrypted under it is lost. This is AWS's own documented default for a
reason.

**Compensating controls.** The statement grants nothing by itself; it defers the
decision to IAM, where the exec role holds only the scoped KMS actions defined
in `security/iam-terraform-role`. Data-plane access is separately confined by
`kms:ViaService`. The exec role's guardrail additionally denies
`kms:ScheduleKeyDeletion`/`PutKeyPolicy` outside project keys.

## Cost profile

| Line item | Rate | This module |
|---|---|---|
| Customer-managed key | $1.00 / month | 1 key → **$1.00/mo** |
| Requests | $0.03 / 10,000 | negligible at dev volume |
| Rotation | free (no per-rotation charge) | — |

**Estimated: ~$1/month.** The first always-on charge in the estate, and a
deliberate one — it is the precondition for encrypting everything that follows.

## Verification

`tests/integration/test_kms.py` asserts against the live API: rotation enabled
and its period, key spec and state, alias resolves to the key, mandatory tags,
and — the ones that matter — that the key policy denies direct `Decrypt`
outside the service path, and that `kms:ScheduleKeyDeletion` behaves as
intended for the exec role.
