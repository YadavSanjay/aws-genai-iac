# `compute/ec2-app` — container application host

A private-subnet EC2 instance running Docker Compose workloads. The primary
compute pattern for the Faultline, MacroRAG and XbrlRag app tiers.

Reachable only through the ALB, egressing only through the NAT instance,
administered only through SSM Session Manager. No public address, no key pair,
no inbound rule of its own.

## Resources

| Resource | Purpose |
|---|---|
| `aws_instance.app` | The host, arm64, private subnet |
| `aws_iam_role` + instance profile | SSM, scoped ECR pull, scoped secret read |
| `aws_iam_role_policy` | ARN-scoped runtime grants |

The security group is **not** created here — it comes from
`networking/security-groups`, so tiers reference each other by group id rather
than every app inventing its own rules.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` / `app_name` | string | — | Names become `<prefix>-<app>` |
| `subnet_id` | string | — | **Private** subnet |
| `security_group_ids` | list(string) | — | Normally the app tier group |
| `instance_type` | string | `t4g.large` | Graviton; see arm64 note |
| `root_volume_gb` | number | `30` | Billed while stopped |
| `data_volume_gb` | number | `0` | Optional dedicated data volume at `/dev/sdf`; survives instance replacement. 0 = none |
| `kms_key_arn` | string | — | Root volume, secrets, image layers |
| `permissions_boundary_arn` | string | — | Required by the exec role |
| `ecr_repository_arns` | list(string) | `[]` | Empty grants no pull access |
| `secret_arns` | list(string) | `[]` | Empty grants no secret access |
| `s3_bucket_arns` | list(string) | `[]` | Buckets the role may read+write; empty grants none |
| `imds_hop_limit` | number | `1` | 1 = host only; 2 = containers may reach the instance role |
| `compose_bundle_s3_uri` | string | `""` | S3 deploy bundle (compose + configs); empty = docker-only |
| `compose_file_relpath` | string | `""` | Compose file path within the bundle |
| `runtime_env` | map(string) | `{}` | Host-static compose env (`/opt/app/.env`, in user-data — changing it reprovisions) |
| `deploy_env_relpath` | string | `""` | Path in the bundle to a per-deploy env-file (image tags); bump via bundle re-upload + restart, no reprovision |
| `app_env_secret_arn` | string | `""` | Secret rendered verbatim to an env-file each boot |
| `app_env_file_path` | string | `/opt/app/secret.env` | Where that secret renders; match compose `env_file:` |
| `data_mount_point` | string | `/mnt/data` | Where the data volume mounts (when `data_volume_gb > 0`) |
| `start_cron` / `stop_cron` | string | `""` | EventBridge Scheduler crons; both empty = no schedule |
| `schedule_timezone` | string | `America/New_York` | IANA name, so the window holds across DST |
| `schedule_enabled` | bool | `true` | `false` disables **both** the stop and the start |
| `service_discovery_namespace_id` | string | `""` | Cloud Map namespace to register in; empty registers nothing |
| `service_discovery_namespace_name` | string | `""` | That namespace's DNS suffix. Required when the id is set — a precondition fails the plan otherwise |
| `discovery_service_name` | string | `""` | DNS label to register; defaults to `app_name` |
| `tags` | map(string) | `{}` | |

## Outputs

`instance_id`, `private_ip`, `role_arn`, `role_name`, `availability_zone`,
`session_manager_command`, `discovery_fqdn`.

## Consumers MUST use the `//` subdir source form

```hcl
terraform {
  source = "${get_repo_root()}/infra/modules//compute/ec2-app"
}
```

Not `.../infra/modules/compute/ec2-app`. This module calls a sibling module
(`../../scheduler/eventbridge`), and Terragrunt copies **only** the directory
named before the `//` into its cache. Without the marker the sibling is outside
the copy and `init` fails with:

```
Error: Unreadable module directory
Unable to evaluate directory symlink: ..\..\scheduler
```

The `//` makes Terragrunt copy `infra/modules` and use `compute/ec2-app` as the
working directory, so the relative reference resolves. It is a path change only —
resource addresses are unaffected, so switching an applied component to it plans
as *no changes*.

## The start/stop schedule is created here, not in a component of its own

Setting `start_cron` + `stop_cron` instantiates `scheduler/eventbridge` as a
nested module, naming its resources `<name_prefix>-<app_name>-{scheduler,start,
stop}`. Omit them and no schedule exists, so an always-on tier is unaffected.

Same reasoning as service discovery below, and the same failure it avoids: a
separate `<app>-app-schedule` component stores a **copy** of the instance id, so
reprovisioning the host without re-applying that component leaves the schedule
driving a terminated instance — silently, because a scheduler invocation against
a dead id just fails in the background. Here the target is
`aws_instance.app.id`, rewritten by the same apply that replaces the host.

The schedule resources do not feed `user_data`, so adding a window to a running
host is an **add**, never a replacement.

> **`schedule_enabled = false` disables the START as well as the STOP.** It is
> the one-night-override switch, not a way to keep a host up: nothing brings the
> instance back on its own until it is set true again.

## Service discovery is registered here, not in a component of its own

Setting `service_discovery_namespace_id` registers the host in Cloud Map, so
callers reach it at `<discovery_service_name>.<namespace>` instead of a private
IP. Needed as soon as one app tier calls another: Faultline's `scenariogen`
reaches XbrlRag and MacroRAG over REST.

The placement is the point. The record's value **references**
`aws_instance.app.private_ip` in this module's own state, so Terraform rewrites
it during the same apply that replaces the instance — there is no window where
the name points at a dead host, and nothing to remember to re-apply.

A separate component holding the same value would be a *copy*, and copies rot:
that is exactly how an `app-schedule` component ends up pinned to a terminated
instance id after its host is reprovisioned. Prefer wiring consumers to
`discovery_fqdn` over `private_ip` for the same reason.

Two properties make this safe in practice:

- a VPC instance keeps its private address across stop/start, so a scheduled
  tier does not churn its record daily;
- the record TTL is 10s, so the brief window during a replacement clears fast.

The residual risk is an instance changed **outside** Terraform, which no module
can prevent. `tests/integration/test_app_discovery.py` fails on it, because the
runtime symptom will not: a stale A record still resolves, and the caller times
out as though the remote application were broken.

## arm64 is a real constraint, not just a discount

`t4g.large` is ~20% cheaper than `t3.large` for equivalent performance — but
**only works if the container image is built for arm64**. A mismatched image
fails at container start with `exec format error`, which reads like a corrupt
image rather than an architecture mismatch.

Build with `docker buildx build --platform linux/arm64`, or switch
`instance_type` to `t3.large` and accept the ~20%.

## Security posture

- **No public IP, private subnet.** Ingress via the ALB, egress via NAT.
- **No key pair, no SSH.** Session Manager only — the agent dials outbound and
  needs no inbound rule.
- **IMDSv2 required, hop limit 1.** The hop limit specifically stops a container
  reaching instance metadata and assuming the instance role, which is the
  standard container-escape-to-credentials path.
- **Root volume encrypted** with the project CMK.
- **ECR, Secrets and S3 access are ARN-scoped.** The role can pull *its own*
  images, read *its own* secrets, and read+write *its own* buckets — not every
  image, secret and bucket in the account, which is what an unscoped `ecr:*` /
  `secretsmanager:*` / `s3:*` grant would give. There are negative tests
  asserting it cannot read another application's secret or an unrelated bucket.
  S3 object encryption rides the same CMK via the `DecryptViaServices` grant, so
  no separate key wiring is needed.
- `ecr:GetAuthorizationToken` is necessarily on `*` — it mints a registry-wide
  login token and accepts no resource. The restriction lives in the separate
  pull statement.

## The bootstrap is a systemd unit, not one-shot cloud-init

`user-data.sh.tftpl` renders a bootstrap where `cloud-init` (first boot only)
installs Docker + the Compose plugin + the AWS CLI, mounts the data volume via
fstab, writes the non-secret project env (`/opt/app/.env`), and writes
`app-deploy.sh` plus a systemd `app.service` that runs it. **`app.service` runs
on every boot.**

That split is deliberate. `cloud-init` runs on **first boot only**, and these
instances are stopped and started daily for cost. The deploy work — `s3 sync`
the bundle, render the secret env-file, ECR login, `docker compose pull && up`
— must happen on **every** boot, so it lives in the systemd unit, not cloud-init.
Anything one-shot works on day one and silently does nothing on day two, the same
trap the NAT instance's iptables rules avoid.

The instance re-pulls its images on every start, which is fine: in-region ECR
pulls are free *and* bypass NAT via the S3 gateway endpoint, since image layers
live in S3. The deploy bundle sync rides the same gateway endpoint.

Set `compose_bundle_s3_uri` empty to get a docker-only host (no app); supply it
plus `compose_file_relpath`, `runtime_env` and `app_env_secret_arn` to run a
stack. The bundle must preserve the compose file's relative-path layout so its
`../config` / `../otel` mounts resolve.

## Image bumps do not reprovision (`deploy_env_relpath`)

The image tags are the one thing that changes on every release, so they live in
the **S3 deploy bundle** — an env-file at `deploy_env_relpath` — not `user_data`.
`app-deploy.sh` passes it as a second compose `--env-file` (after the bundle
`s3 sync`), so its tags override the placeholders in `/opt/app/.env`.

Rolling out a new image is therefore a pure deploy-layer action — **no Terraform,
no IAM change, no instance replacement:**

1. bump the tag in the bundle's env-file and re-upload the bundle to S3, then
2. `systemctl restart app.service` on the host (e.g. an SSM RunCommand), which
   re-`s3 sync`s the bundle and runs `compose pull && up -d`.

The role needs nothing new — it already reads the bundle from S3. `user_data`
(and thus `runtime_env`) holds only the host-static config — endpoints, bucket,
secret path — which changes rarely.

## Depends on the NAT instance being up

An instance in a private subnet reaches the SSM service endpoints **through the
NAT**. If the NAT is stopped, this instance cannot register as a managed node
and Session Manager will not connect — even though the instance is healthy.

The NAT window (10:00–22:00) is therefore deliberately *wider* than the app
window (11:00–21:00), with an hour of buffer either side. Starting an app host
outside the NAT window leaves it unmanageable until the NAT returns.

Interface endpoints for SSM would remove this dependency at ~$22/month for three
of them, which is not justified at dev volume — see
[`aws-service-consolidation.md` §2a](../../../../docs/design/aws-service-consolidation.md).

## Cost profile

`t4g.large`, us-east-1:

| | Running 24/7 | Scheduled 10h/day |
|---|---|---|
| Compute | $49.06 | $20.16 |
| 30 GB gp3 root (billed while stopped) | $2.40 | $2.40 |
| **Total** | **$51.46/mo** | **~$22.56/mo** |

For comparison `t3.large` (x86) is $60.74 / $24.96 — Graviton saves ~$4.80/month
on this schedule.

**EBS is the floor.** A stopped instance still pays for its volume, so
`root_volume_gb` is the one number that costs money around the clock. 30 GB
covers the OS, a few container images and SQLite; raise it on evidence.

No public IPv4 charge — the instance has no public address.

## Verification

`tests/integration/test_macrorag_instance.py` asserts private placement, no
public IP, arm64, IMDSv2 with hop limit 1, encrypted root volume, no key pair,
SSM managed-node registration, and — the ones that matter — that the role can
read its **own** secret and pull its **own** images, and **cannot** read a
different application's secret.
