# `compute/ecs-service` — Fargate service (Cloud Map service discovery; dormant external-ALB mode)

A container application on **ECS Fargate**, for services that do not fit the
compose-on-EC2 pattern (`compute/ec2-app`). Built for **RagInference**: a
CPU/ARM64 model server that syncs its weights from S3 at startup, serves an
internal HTTP API, and rides a scheduled scale-to-zero.

Tasks run in **private subnets with no public IP**, reach AWS through VPC
endpoints/NAT, and are administered with **ECS Exec** — the Fargate equivalent of
Session Manager, since there is no SSH into a Fargate task.

## Reachability: this module does NOT own a target group

ECS refuses to create a service whose target group is not **already** associated
with a load balancer — so a module that owns the target group but not the
listener cannot bring a service up on its own (a chicken-and-egg the ALB side
must resolve). This module therefore attaches to reachability provided from
outside, in one of two modes:

- **Cloud Map service discovery** (`service_discovery_namespace_id`) — the
  default for **backend** services. The module creates a Cloud Map service named
  `app_name` in the shared namespace (`networking/dns`) and registers tasks, so
  the service resolves at `<app_name>.<namespace>:<container_port>` in-VPC — no
  load balancer, no listener, unaffected by the `ingress_mode` toggle. A
  `container_health_check` gates the ECS deployment on `/readyz`; a caller may
  still briefly resolve a warming task during a scale-from-zero (the cold-start
  SLO — clients retry).
- **External target group** (`target_group_arn`) — for a service that genuinely
  needs the shared ALB: pass an *already-LB-associated* target group ARN and the
  service registers into it. **Currently dormant** — the `edge/alb` module's support
  for externally-owned target groups was reverted ("no user, would
  trap the next person who reaches for it"), so nothing in this repo produces such an
  ARN today. The input is retained for a future ALB-attached service; see
  [`edge/alb/README.md`](../../edge/alb/README.md).

Set neither for a headless service. RagInference uses **Cloud Map**.

## Resources

| Resource | Purpose |
|---|---|
| `aws_ecs_cluster` (+ capacity providers) | FARGATE / FARGATE_SPOT, Container Insights off |
| `aws_ecs_task_definition` | ARM64, awsvpc, weights synced at runtime |
| `aws_ecs_service` | circuit-breaker rollback, `ignore_changes` on desired_count |
| `aws_service_discovery_service` | Cloud Map A record (only when a namespace id is given) |
| `aws_iam_role.execution` (+ policy) | ECR pull, log write, secret read — ARN-scoped |
| `aws_iam_role.task` (+ policy) | scoped S3 read, KMS decrypt, ECS Exec channels |
| `aws_cloudwatch_log_group` ×2 | app log + ECS Exec audit, CMK-encrypted, retention set |
| `aws_appautoscaling_target` + scheduled actions | opt-in scale-to-zero (`enable_autoscaling`) |
| `aws_cloudwatch_metric_alarm` ×2 | opt-in CPU + memory alarms (`enable_alarms`) |

The security group is **not** created here — it comes from
`networking/security-groups`, so tiers reference each other by group id.

## Key inputs

| Name | Default | Notes |
|------|---------|-------|
| `image` | — | Full ECR URI **with a git-SHA tag** (ECR is IMMUTABLE; no `:latest`) |
| `cpu` / `memory` | `1024` / `2048` | Must be a valid Fargate pair (RagInference: `4096` / `16384`) |
| `cpu_architecture` | `ARM64` | Image must match, or "exec format error" at start |
| `container_port` | `8080` | RagInference: `8799` |
| `environment` / `secrets` | `{}` | Secrets go in `secrets` (valueFrom), never `environment` |
| `container_health_check` | `null` | Docker HEALTHCHECK on the readiness path — gates the ECS deployment on `/readyz`; give it a generous `start_period` |
| `service_discovery_namespace_id` / `_name` | `""` | Cloud Map mode (backend default) |
| `target_group_arn` | `""` | External-ALB mode — must be already LB-associated |
| `health_check_grace_period_seconds` | `300` | Passed through **only** in target-group mode (ECS rejects it otherwise) |
| `ecr_repository_arns` | `[]` | Execution-role pull scope |
| `task_read_bucket_arns` | `[]` | Task-role S3 read scope (the weights bucket) |
| `kms_key_arn` / `permissions_boundary_arn` | — | CMK + boundary on **both** roles |
| `desired_count` | `1` | Initial only — the service ignores later changes |
| `enable_execute_command` | `true` | ECS Exec for troubleshooting |
| `use_fargate_spot` | `false` | ~70% cheaper, interruptible |
| `wait_for_steady_state` | `false` | Block apply until the task is healthy (or rolls back) |
| `enable_autoscaling` + crons | `false` | Scheduled scale-to-zero; land always-on first |
| `enable_alarms` + `alarm_*` | `false` | CPU/memory alarms (AWS/ECS metrics, free); `alarm_actions` for an SNS topic |

## Outputs

`cluster_arn`, `cluster_name`, `service_name`, `service_arn`,
`task_definition_arn`, `service_discovery_service_arn`, `service_fqdn`
(`<app>.<namespace>`), `execution_role_arn`, `task_role_arn`, `task_role_name`,
`log_group_name`, `autoscaling_resource_id`, `execute_command`.

## Security posture

- **No public IP, private subnets.** Ingress from the callers' security groups
  (Cloud Map mode) or the ALB (target-group mode); egress via NAT and VPC
  endpoints.
- **Two roles, least-privilege, both boundaried.** The **execution** role pulls
  *its own* images and reads *its own* injected secrets; the **task** role reads
  *its own* buckets and nothing else. Neither carries the broad AWS-managed
  `AmazonECSTaskExecutionRolePolicy` — the grants are ARN-scoped inline. Both
  carry the permissions boundary, so a role created by IaC cannot escalate.
- **`ecr:GetAuthorizationToken` is necessarily on `*`** (it mints a registry-wide
  token and accepts no resource); the pull itself is scoped by ARN.
- **KMS-encrypted** log group and ECS Exec channel; the task role can `Decrypt`
  (read) the weights, the execution role can decrypt image layers.
- **No SSH.** ECS Exec (`ssmmessages` channels) is the only interactive path.

### Deliberate relaxations (each with a compensating control)

- **`readonlyRootFilesystem = false`.** The app writes ~4 GB of weights to
  `HF_HOME` at startup, so a read-only root would break the documented model
  sync. Compensating: the task carries no long-lived on-disk secret and is
  replaced rather than patched. (`checkov` CKV_AWS_336 skipped with this reason.)
- **Container Insights disabled.** Bills per ingested metric; not justified for a
  single dev task whose signal is the container health check and the app's own
  `/metrics`. Enable in prod. (CKV_AWS_65 skipped.)

## Scale-to-zero

`enable_autoscaling = true` registers an Application Auto Scaling target on the
service's `DesiredCount` (`min = 0`) and, if `scale_up_cron` / `scale_down_cron`
are set, scheduled actions in `schedule_timezone`. The service always
`ignore_changes` on `desired_count`, so autoscaling — not a stale Terraform
literal — owns capacity. **Land the service always-on (`enable_autoscaling =
false`, `desired_count = 1`) and verify it healthy first**, then enable the
schedule; a scale-to-zero applied before verification hides startup failures
behind an off task.

## Cost profile

Fargate ARM64, us-east-1 (~$0.03238/vCPU-hr, ~$0.00356/GB-hr):

| Size | 24/7 | Scheduled ~10h/day |
|---|---|---|
| 4 vCPU / 16 GB (RagInference) | ~$135/mo | **~$45–57/mo** |
| + CloudWatch Logs | a few $/mo at dev volume | — |
| Cluster / Cloud Map service | free | free |

`FARGATE_SPOT` cuts compute ~70% at the cost of interruption. Fargate has **no
cluster charge** and no always-on line item once scaled to zero — the design
goal. Cloud Map adds only the namespace's ~$0.50/mo private zone (billed by
`networking/dns`, not here).

## Verification

Post-apply, `tests/integration/` should assert against the live API: task
`RUNNING`/`HEALTHY` on ARM64 with the expected cpu/memory, private placement with
no public IP, the Cloud Map service resolves `<app>.<namespace>` to the task IP,
the two roles are distinct and boundaried, the task role **can** read its weights
bucket
and **cannot** read another, the log group has retention set and is CMK-encrypted,
and — the one that matters for scale-to-zero — that ECS Exec reaches a running
task and `/readyz` returns 200 once warm.
