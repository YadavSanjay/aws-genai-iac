# `networking/nat-instance` — NAT via a t4g.nano

A NAT Gateway replacement. Rationale in
[`aws-service-consolidation.md` §2a](../../../../docs/design/aws-service-consolidation.md):
a NAT Gateway bills **$0.045/hour for every hour it exists** and has no stop
state, so with dev instances scheduled off-hours it would become the largest
line item in the environment. An EC2 instance genuinely stops.

## Resources

| Resource | Purpose |
|---|---|
| `aws_instance.nat` | The forwarder, `source_dest_check = false` |
| `aws_security_group.nat` | Private-tier ingress, unrestricted egress |
| `aws_iam_role` + instance profile | Session Manager access only |
| `aws_route.private_default` | `0.0.0.0/0` from private tables → the ENI |

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | string | — | e.g. `genai-dev` |
| `vpc_id` | string | — | |
| `public_subnet_id` | string | — | Must have an IGW default route |
| `private_route_table_ids` | list(string) | — | Prefer same-AZ; see cost note |
| `private_subnet_cidrs` | list(string) | — | Permitted source ranges |
| `instance_type` | string | `t4g.nano` | Sizing is bandwidth, not CPU |
| `permissions_boundary_arn` | string | — | Required by the exec role |
| `kms_key_arn` | string | — | Encrypts the root volume |
| `root_volume_gb` | number | `8` | |
| `tags` | map(string) | `{}` | |

## Outputs

`instance_id`, `network_interface_id`, `private_ip`, `security_group_id`,
`role_arn`, `ami_id`.

## The three things that make this work

### `source_dest_check = false`

The single line that turns an instance into a NAT. With the check on, EC2 drops
any packet whose source or destination is not the instance itself — which is
every forwarded packet. Symptom if missed: private instances have a correct
route and still cannot reach anything.

### NAT rules applied by a systemd unit, not cloud-init

`cloud-init` runs on **first boot only**. This instance is designed to be
stopped and started on a schedule, so one-shot `iptables` commands would vanish
on the second start — and present as "the internet stopped working" with a
perfectly healthy-looking instance.

The unit reapplies on every boot and the rules are added idempotently, so
repeated starts do not stack duplicates.

### Routes target the ENI, not the instance

The ENI survives a stop/start, so the route stays valid across the scheduled
shutdown. Traffic blackholes while the instance is down and resumes when it
returns — no route churn, and no automation needed to restore egress. This is
precisely what a NAT Gateway cannot do.

## Verifying it actually forwards — the mistake worth not repeating

Every attribute on this instance can be correct while it forwards nothing.

On first build, `configure-nat.service` failed because **AL2023 does not ship
`iptables`** (it normally arrives as a Docker dependency, so it is easy to
assume present). The instance came up healthy, `source_dest_check` was off, the
routes pointed at its ENI, the security group was right — and every private
subnet had no egress.

None of the obvious checks catch this:

- The NAT's **own** SSM registration proves nothing: it sits in a *public*
  subnet and reaches SSM straight out the IGW.
- **Flow logs delivering** proves nothing: they are emitted by VPC
  infrastructure, not by traffic through the NAT.

**The real proof is a PRIVATE instance registering as an SSM managed node.** A
private-subnet host can only reach the SSM endpoints through this NAT, so that
single assertion exercises the whole path — routes, `source_dest_check`,
masquerading, and the security group. It lives in
`tests/integration/test_macrorag_instance.py`, not in this module's own tests,
because it needs a private-subnet instance to exist.

## Security posture

- **IMDSv2 required.** IMDSv1's unauthenticated GET is the classic SSRF path to
  instance credentials; a required token makes it a two-step exchange that
  simple request forgery cannot complete.
- **No SSH, no key pair.** Access is Session Manager, whose agent dials
  outbound. The instance role exists solely for that — the NAT function itself
  needs no AWS permissions.
- **Root volume encrypted** with the project CMK.
- **Kernel hardening** in `user-data.sh`: ICMP redirects are neither accepted
  nor sent, since on a forwarding host they can reroute traffic through an
  attacker-chosen next hop.
- **Ingress is wide by protocol but narrow by source.** A NAT forwards whatever
  the private tier sends, so restricting protocols would break anything not
  anticipated. The control is the source: private subnet CIDRs only, never the
  internet.

### Requires an app-boundary grant

The instance role carries `AmazonSSMManagedInstanceCore`, but a role is capped
by the permissions boundary. Until `RuntimeSsmManagedNode` was added to
`security/iam-terraform-role`, that boundary capped SSM away entirely and
Session Manager failed in a way that looks like a networking fault — the
instance simply never appears as a managed node.

## Accepted risks

Stated plainly, because they are real:

- **Single point of failure.** No health check, no automatic replacement. If the
  instance dies, private-tier egress dies with it until someone notices.
  Acceptable in dev; **prod keeps the NAT Gateway.**
- **We own patching.** Via SSM Patch Manager. The AMI is pinned by
  `ignore_changes` after creation, so a newer AL2023 release does not silently
  replace the instance mid-plan — refresh is a deliberate taint-and-replace.
- **Bandwidth is bounded** by the instance type: `t4g.nano` sustains ~32 Mbps
  baseline with burst to ~5 Gbps. Fine for LLM API calls (small payloads) and
  irrelevant for container pulls, which bypass NAT entirely via the S3 gateway
  endpoint. Move up on measured throughput, not intuition.

## Expect a slow first apply

`aws_instance.nat` took **15m52s** on first creation (observed 2026-07-21). That
is not a hang and not a defect.

The IAM role and instance profile are created in the same apply, and IAM is
eventually consistent. `RunInstances` rejects a just-created instance profile
until it has propagated, so the provider retries for as long as it takes —
roughly 16 minutes here. Subsequent applies, where the profile already exists,
complete in under a minute.

If it appears stuck, check whether the role exists (`aws iam list-roles`) before
concluding anything is wrong.

## Cost profile

| | Running | Stopped |
|---|---|---|
| `t4g.nano` compute | $3.07/mo | **$0** |
| 8 GB gp3 root volume | $0.64/mo | $0.64/mo |
| Auto-assigned public IPv4 | $3.60/mo | $0 (released) |
| **Total** | **~$7.31/mo** | **~$0.64/mo** |

At ~36% uptime (12h × 5 days) that lands near **$3/month**, against
**$32.85/month** for an unpausable NAT Gateway — roughly **91% cheaper**.

**Watch cross-AZ data transfer.** Traffic from a private subnet in one AZ to a
NAT device in another is billed $0.01/GB in *each* direction, which can exceed
the instance cost outright. Pass `private_route_table_ids` for the same AZ as
`public_subnet_id`, or accept the charge knowingly.

An Elastic IP is deliberately not used: it would cost the same while running
*and* keep billing while stopped.

## Verification

`tests/integration/test_nat_instance.py` asserts `source_dest_check` is off,
IMDSv2 required, root volume encrypted with the project CMK, no public ingress,
the private route tables point at the ENI, and — the one a config read cannot
establish — that the instance is registered as an **SSM managed node**, which
proves the boundary grant, the instance role and the agent all actually work.
