# `networking/subnets` — subnets and route tables

Public and private tiers across N availability zones, a shared public route
table pointing at the IGW, and one private route table per AZ.

**No NAT route.** Private subnets carry local routes only until an egress device
exists — see [`aws-service-consolidation.md` §2a](../../../../docs/design/aws-service-consolidation.md)
for why that is a scheduled NAT instance rather than a NAT Gateway.

## Resources

| Resource | Count | Purpose |
|---|---|---|
| `aws_subnet.public` | per AZ | Internet-facing tier (ALB, NAT device) |
| `aws_subnet.private` | per AZ | Everything else |
| `aws_route_table.public` | 1 | Shared; default route to the IGW |
| `aws_route_table.private` | per AZ | Local routes only, for now |
| `aws_route_table_association.*` | per subnet | Explicit — nothing relies on the main table |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `vpc_id` | string | — | VPC to build in |
| `vpc_cidr` | string | — | Subnet ranges are carved from this |
| `internet_gateway_id` | string | `""` | Empty means no default route |
| `az_count` | number | `2` | 1–4 |
| `subnet_newbits` | number | `4` | `/16` + 4 → `/20` subnets |
| `private_subnet_offset` | number | `8` | Keeps private in a separate block |
| `tags` | map(string) | `{}` | |

## Outputs

`availability_zones`, `public_subnet_ids`, `private_subnet_ids`,
`public_subnet_ids_by_az`, `private_subnet_ids_by_az`,
`public_route_table_id`, `private_route_table_ids`,
`private_route_table_ids_by_az`, `all_route_table_ids`.

The `_by_az` maps matter when placement is AZ-sensitive — putting a NAT instance
in the same AZ as the subnets routing to it avoids cross-AZ data charges.

## Addressing

With the defaults and a `10.10.0.0/16` VPC:

| Tier | AZ a | AZ b |
|---|---|---|
| Public | `10.10.0.0/20` | `10.10.16.0/20` |
| Private | `10.10.128.0/20` | `10.10.144.0/20` |

Public occupies low indices and private a clearly separated block, so the tier
is obvious from the CIDR alone when reading a route table. Roughly 4,000 usable
addresses per subnet, with most of the VPC left unallocated for future tiers.

## Security posture

### `map_public_ip_on_launch` is false everywhere — including public subnets

Auto-assignment means a workload becomes internet-addressable purely by landing
in a subnet, with no explicit decision recorded anywhere in code. Anything that
genuinely needs a public address requests one at launch, which is visible in a
plan and in review.

This is also what `CKV_AWS_130` checks.

### Route table associations are explicit

Every subnet is associated with a route table by name. Nothing falls through to
the VPC's main route table, which carries only the local route — so a subnet
created outside IaC fails closed rather than inheriting connectivity.

### Private subnets have no egress path

Until a NAT device is added, private subnets can reach only the VPC-local range.
That is deliberate for this step: it means the public/private split is real and
testable now, rather than asserted.

## Cost profile

**$0.00/month.** Subnets, route tables and associations are all free, as are
availability zones themselves.

Worth being explicit, because AZ count is normally a cost lever: it costs
nothing *here*. The per-AZ charges arrive with NAT devices, load balancer nodes
and cross-AZ data transfer ($0.01/GB each direction) — which is exactly why the
private route tables are per-AZ, so a future egress device can be reached
without crossing a zone boundary.
