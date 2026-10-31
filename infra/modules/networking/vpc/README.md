# `networking/vpc` — VPC skeleton

The network container, its egress gateway, a stripped default security group,
and flow logging. **No subnets, route tables or NAT** — those are separate,
independently appliable steps, and nothing here depends on them.

## Resources

| Resource | Purpose |
|---|---|
| `aws_vpc` | The VPC, DNS support and hostnames on |
| `aws_default_security_group` | Stripped to deny-all — see below |
| `aws_internet_gateway` | Optional; free; prerequisite for NAT |
| `aws_flow_log` | Optional; delivered to S3 in Parquet |

## Usage (via Terragrunt)

```hcl
terraform { source = "${get_repo_root()}/infra/modules/networking/vpc" }

inputs = {
  name_prefix              = "genai-dev"
  cidr_block               = "10.10.0.0/16"
  flow_log_destination_arn = dependency.logs_bucket.outputs.bucket_arn
}
```

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | Prefix for resource names. |
| `cidr_block` | string | — | VPC IPv4 CIDR. Validated; must be `/24` or larger. |
| `enable_dns_support` | bool | `true` | Needed for VPC endpoints and private zones. |
| `enable_dns_hostnames` | bool | `true` | Needed for private hosted zones. |
| `create_internet_gateway` | bool | `true` | Free; exposes nothing on its own. |
| `flow_log_destination_arn` | string | `""` | S3 bucket ARN; empty disables flow logging. |
| `flow_log_traffic_type` | string | `"ALL"` | `ALL` / `ACCEPT` / `REJECT`. |
| `flow_log_max_aggregation_interval` | number | `600` | 60 or 600 seconds. |
| `flow_log_file_format` | string | `"parquet"` | `plain-text` or `parquet`. |
| `tags` | map(string) | `{}` | Extra tags. |

## Outputs

| Name | Description |
|------|-------------|
| `vpc_id` | ID of the VPC. |
| `vpc_arn` | ARN of the VPC. |
| `cidr_block` | VPC CIDR. |
| `internet_gateway_id` | IGW id, or null when not created. |
| `default_security_group_id` | The stripped default SG — exported so a check can assert nothing uses it. |
| `flow_log_id` | Flow log id, or null when disabled. |

## Security posture

### The default security group is stripped, not ignored

AWS creates a default SG with every VPC carrying an allow-all-from-self ingress
rule and unrestricted egress. **It cannot be deleted**, and anything launched
without an explicit security group lands in it.

Declaring `aws_default_security_group` with no `ingress` or `egress` blocks
removes every rule. The default becomes deny-all, so a workload that
accidentally uses it fails closed and visibly rather than silently acquiring
broad connectivity. It is tagged `-default-DO-NOT-USE` to make the intent
obvious in the console.

Managed here rather than in the later security-group step because AWS creates it
the instant the VPC exists — deferring would leave a window where it is open.

### The Internet Gateway is not exposure

Attaching an IGW grants no reachability by itself. Traffic additionally requires
a route table entry pointing at it, a subnet using that route table, and a
permissive security group. None of those exist yet.

### Flow logs need no IAM role

That requirement applies only to the CloudWatch Logs destination. S3 delivery is
authorised entirely by the destination bucket's policy plus, for SSE-KMS, the
key policy — both configured in `data/s3` and `security/kms` respectively.

## Cost profile

| Line item | Rate | This module |
|---|---|---|
| VPC | free | $0 |
| Internet Gateway | free | $0 |
| Default security group | free | $0 |
| Flow logs → S3 (vended logs) | ~$0.25/GB ingested | volume-dependent |
| Flow-log storage | $0.023/GB-month | bounded by the archive's 90-day expiry |

**Estimated: well under $1/month for a dev VPC with no workloads.** The
recurring charge in this tier is the NAT Gateway (~$33/month), deliberately
*not* here — it arrives with its own step.

Three cost choices worth noting:

- **S3, not CloudWatch Logs** — $0.25/GB vs $0.50/GB. Logs Insights is not worth
  double the ingest cost at dev volume.
- **Parquet** — roughly 20% smaller on ingest, and columnar, so Athena scans a
  fraction of the bytes.
- **600s aggregation** — fewer, larger objects, cheaper to store and query. The
  cost is coarser timing, which only matters while investigating live.

`flow_log_traffic_type = "REJECT"` is worth revisiting before prod: materially
cheaper on a busy VPC while retaining most security-relevant signal.

## Verification

Flow-log misconfiguration is **silent**. A missing KMS grant or bucket-policy
statement leaves the flow log reporting `ACTIVE` while delivering nothing, which
presents as a networking problem rather than a permissions one.

`tests/integration/test_vpc.py` therefore asserts an object has actually landed
in the destination bucket — not merely that the flow log exists. First delivery
takes roughly 5–10 minutes after the VPC starts seeing traffic.
