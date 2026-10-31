# `registry/ecr` — container repositories

KMS-encrypted, immutable tags, scanned on push, and lifecycled.

Intended full scope across subsystems: `arag`, `arag-ui`, `arag-ingest`,
`macrorag`, `macrorag-ui`, `quantlibpricer`, `raginference`. Repositories are
created per environment as their workloads land, not all at once.

## Resources

| Resource | Purpose |
|---|---|
| `aws_ecr_repository` | One per entry in `repositories` |
| `aws_ecr_lifecycle_policy` | Two rules — untagged expiry, tagged retention |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `repositories` | list(string) | — | e.g. `["genai-dev/macrorag"]` |
| `kms_key_arn` | string | — | Required; no unencrypted path |
| `image_tag_mutability` | string | `IMMUTABLE` | See below |
| `scan_on_push` | bool | `true` | Basic scanning is free |
| `keep_tagged_images` | number | `5` | Retention bound |
| `untagged_expiry_days` | number | `3` | |
| `force_delete` | bool | `false` | Destroy guard |
| `tags` | map(string) | `{}` | |

## Outputs

`repository_urls`, `repository_arns`, `registry_id`.

Use `repository_arns` to scope pull permissions on instance and task roles —
`ecr:*` on `*` is not necessary and should not survive review.

## Security posture

### Immutable tags, and what that costs you

`IMMUTABLE` means a tag, once pushed, cannot be repointed at different content.
That closes the window where an audited image tag is quietly replaced, and makes
a deployed tag a reliable record of what is actually running.

**The tradeoff is real:** `:latest` stops working as a rolling tag. Every build
must carry a distinct tag, typically the git SHA. That is better practice
regardless, but a push workflow relying on `:latest` has to change — and the
failure surfaces as `ImageTagAlreadyExistsException` on the second push, which
does not obviously mention mutability.

This also satisfies `CKV_AWS_51`.

### KMS rather than the AES256 default

Image layers are covered by the same key policy and rotation as everything else.
No key-policy change was needed: `ecr` is already in the CMK's `kms:ViaService`
list.

### Scan on push

Basic scanning is enabled and free. **Enhanced scanning (Inspector) is not
enabled** — it is charged per image and per rescan, while basic scanning already
covers the OS-package CVEs that dominate a container built on a standard base
image. Worth revisiting for prod, where application-dependency scanning earns
its cost.

Note that scanning *reports*; it does not block. Nothing here prevents deploying
an image with known criticals — that is a pipeline gate, not a registry setting.

## Cost profile

| Line item | Rate |
|---|---|
| Storage | $0.10 / GB-month |
| Pull to same-region EC2/ECS | free |
| Basic scanning | free |

**The lifecycle policy is the cost control, and it is mandatory here.** An image
repository is the classic silent leak: every build adds layers, nothing removes
them, and growth is invisible until it lands on a bill.

Two rules apply — untagged images expire after `untagged_expiry_days` (residue
of overwritten or failed pushes, referenced by nothing), and only the most
recent `keep_tagged_images` are retained.

Layers are shared between builds, so N versions cost considerably less than N
times one image. A typical Python application image of 1–2 GB with 5 retained
versions lands around **$0.30–0.60/month**.

Pulls from EC2 or ECS in the same region are free *and* bypass NAT entirely,
because ECR image layers are served from S3 and the VPC has an S3 gateway
endpoint.

## Verification

`tests/integration/test_ecr.py` asserts encryption type and key, tag
immutability, scan-on-push, and — the one a config read alone will not
establish — that both lifecycle rules exist with the expected bounds, since a
repository without them grows without limit and nothing fails.
