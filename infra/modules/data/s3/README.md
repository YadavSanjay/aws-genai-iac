# `data/s3` — secure-by-default bucket

There is no unencrypted, publicly-reachable, or lifecycle-free path through this
module. Callers choose *retention*, not whether to have any.

## Resources

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | The bucket |
| `aws_s3_bucket_public_access_block` | All four blocks on — **not configurable** |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` — ACLs disabled |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-KMS + bucket key |
| `aws_s3_bucket_versioning` | On by default |
| `aws_s3_bucket_lifecycle_configuration` | Expiry, transitions, MPU abort |
| `aws_s3_bucket_logging` | Optional access logs |
| `aws_s3_bucket_policy` | TLS-only deny + optional encryption-header deny + caller statements |

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `bucket_name` | string | — | Full name; S3 names are **globally** unique |
| `kms_key_arn` | string | — | Required; no unencrypted path |
| `versioning_enabled` | bool | `true` | |
| `force_destroy` | bool | `false` | The destroy guard — see below |
| `expiration_days` | number | `0` | 0 = never; needs a stated reason |
| `noncurrent_expiration_days` | number | `30` | Must be > 0 |
| `abort_incomplete_upload_days` | number | `7` | Always applied |
| `transitions` | list(object) | `[]` | Mind storage-class minimums |
| `access_log_bucket` / `access_log_prefix` | string | `""` | Empty disables |
| `extra_policy_documents` | list(string) | `[]` | Merged into the single bucket policy |
| `restrict_encryption_header` | bool | `true` | See below |
| `tags` | map(string) | `{}` | |

## Outputs

`bucket_id`, `bucket_arn`, `bucket_domain_name`, `kms_key_arn`.

## Security posture

- **Public access blocked unconditionally.** Not a variable. A bucket in this
  project is never public; an exception would be a new module, not a flag here.
- **ACLs disabled** via `BucketOwnerEnforced`. This closes the "public via
  object ACL" path that a public access block alone does not — access is
  governed only by policy and IAM.
- **SSE-KMS required.** `kms_key_arn` has no default and is ARN-validated.
- **TLS enforced** by an explicit `Deny` on `aws:SecureTransport = false`.
- **Bucket keys enabled** — up to 99% fewer KMS requests, no security tradeoff.

### Why the encryption-header deny is the lenient form

`restrict_encryption_header` denies `PutObject` that *explicitly requests*
something other than `aws:kms`. It deliberately does **not** deny uploads that
omit the header.

The strict form is a common hardening recipe, but here it would be theatre:
bucket default encryption already encrypts headerless uploads with the same
CMK, so the object lands KMS-encrypted either way. What the strict form *does*
reliably do is break AWS log-delivery services, several of which do not set the
header — producing a silent delivery failure that looks like a networking
problem. The lenient form blocks the real risk (someone forcing `AES256` to
sidestep the CMK) without that.

### `prevent_destroy` limitation, stated plainly

Terraform requires `prevent_destroy` to be a literal, so it cannot be driven by
a variable and this module cannot offer per-environment destroy protection that
way. `force_destroy = false` (the default) is the guard: `terraform destroy`
fails on a non-empty bucket rather than silently emptying it.

For prod buckets holding real data, that is weaker than `prevent_destroy` and
should be supplemented — an SCP or a resource-level deny on `s3:DeleteBucket`
is the durable answer. Not yet implemented; recorded here rather than left as a
surprise.

## Known gaps

Recorded here rather than discovered later:

- **No cross-region replication.** The module does not implement it at all
  (`CKV_AWS_144` is skipped). CRR roughly doubles storage cost plus cross-region
  transfer, which dev does not justify — but a prod bucket with a genuine DR
  requirement needs this module extended, not merely a different variable.
- **No `prevent_destroy`.** See above; `force_destroy = false` is the guard, and
  it is weaker.
- **No event notifications.** Deliberate — they are a workflow trigger, not a
  security control, and an enabled notification with no consumer is cost with no
  benefit. Attach at the call site when something needs to react.

## Cost profile

The bucket itself is free; you pay for what it holds.

| Line item | Rate (us-east-1) |
|---|---|
| Standard storage | $0.023 / GB-month |
| PUT/COPY/POST/LIST | $0.005 / 1,000 |
| GET | $0.0004 / 1,000 |
| KMS requests | $0.03 / 10,000 — largely avoided by bucket keys |

**Cost control is the lifecycle configuration, and it is mandatory here:**
incomplete multipart uploads always abort (orphaned parts are invisible in the
console but billed forever), and noncurrent versions always expire. Set
`expiration_days` unless there is a written reason to retain indefinitely.

Beware transition minimums — `STANDARD_IA` bills a 30-day minimum and
`GLACIER_IR` 90 days, so transitioning short-lived objects costs *more* than
leaving them in Standard.
