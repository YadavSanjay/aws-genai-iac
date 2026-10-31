# `networking/endpoints` — S3 gateway endpoint

Free, and it does more than save money: S3 traffic stays on the AWS network
instead of traversing the internet gateway or a NAT device.

## Why this matters more than it sounds

**ECR image layers are stored in S3.** Container pulls are usually the largest
S3-shaped traffic a workload generates, so routing them through this endpoint
removes the bulk of it from the NAT path — which is exactly where per-GB charges
would otherwise accumulate.

## Resources

| Resource | Purpose |
|---|---|
| `aws_vpc_endpoint.s3` | Gateway endpoint, associated with the given route tables |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `vpc_id` | string | — | VPC to attach to |
| `region` | string | — | Builds the service name |
| `route_table_ids` | list(string) | — | Every table whose subnets talk to S3 |
| `writable_bucket_arns` | list(string) | — | Bucket ARNs, no `/*` suffix |
| `restrict_endpoint_policy` | bool | `true` | False reverts to AWS's full-access default |
| `tags` | map(string) | `{}` | |

## Outputs

`s3_endpoint_id`, `s3_prefix_list_id`, `s3_endpoint_policy`.

`s3_prefix_list_id` is worth using: as a security-group egress destination it
replaces `0.0.0.0/0` for workloads that only need S3, and the ranges track AWS's
changes automatically.

## Security posture

### The endpoint policy splits on WRITE vs READ, not on ownership

The obvious design — restrict the endpoint to our own buckets — breaks things
badly. ECR layer buckets, Amazon Linux repositories and SSM agent downloads all
live in **AWS-owned** S3 buckets whose names vary by region and change over
time. Denying them produces opaque S3 403s during instance bootstrap that
present as networking faults.

The useful split is different:

| Target | Access |
|---|---|
| Our buckets (`writable_bucket_arns`) | Full |
| Everything else | **Read-only** |

Exfiltration through an S3 endpoint means `PutObject` to a bucket someone else
controls. Reading foreign buckets is not the risk, and is load-bearing. So this
closes the write-out path without an allow-list of AWS bucket names that would
silently break the first time AWS renamed one.

**This is defence in depth, not the primary control.** The app permissions
boundary already scopes `s3` to `genai-*`. The endpoint policy matters because
it applies to *anything* in the VPC — including a compromised process holding
credentials that IAM would otherwise permit.

### Route table coverage is a correctness issue

A gateway endpoint injects a prefix-list route into the tables it is associated
with. **A route table not listed keeps sending S3 traffic the long way** —
through NAT at $0.045/GB, with no error anywhere. The test asserts every route
table in the VPC carries the endpoint route.

## Cost profile

**$0.00/month.** Gateway endpoints have no hourly charge and no data-processing
charge.

Contrast with **interface** endpoints at $0.01/hour per AZ (~$7.30/month each,
plus $0.01/GB). Those are deliberately *not* used in dev: three of them
(ECR/Secrets/Logs) would cost ~$22/month to avoid NAT data charges amounting to
pennies at dev volume. Break-even is roughly 162 GB/month *per service*. See
[`aws-service-consolidation.md` §2a](../../../../docs/design/aws-service-consolidation.md).

The saving here is real but indirect: S3 and ECR traffic that would otherwise be
billed as NAT data processing becomes free.
