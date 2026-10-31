variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "app_name" {
  description = "Application this service runs, e.g. raginference. Used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,32}$", var.app_name))
    error_message = "app_name must be lowercase alphanumeric with hyphens."
  }
}

# --- Task shape --------------------------------------------------------------

variable "image" {
  description = <<-EOT
    Full container image URI INCLUDING the tag, e.g.
    <acct>.dkr.ecr.<region>.amazonaws.com/genai-dev/raginference:<git-sha>.

    A digest or git-SHA tag, never :latest — ECR here is IMMUTABLE and a rolling
    tag cannot be pushed. A tag that does not exist fails the task at RUN time
    (CannotPullContainerError), not at plan time.
  EOT
  type        = string
}

variable "cpu" {
  description = <<-EOT
    Task CPU in Fargate units (1024 = 1 vCPU). Must form a valid Fargate
    CPU/memory pair — AWS rejects invalid combinations at run time.
  EOT
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Task memory in MiB. Must pair validly with cpu for Fargate."
  type        = number
  default     = 2048
}

variable "cpu_architecture" {
  description = <<-EOT
    ARM64 (Graviton, ~20% cheaper — the default) or X86_64.

    ARM64 only works if the image is built for arm64; a mismatched image fails
    at container start with "exec format error", which is easy to misread as a
    corrupt image.
  EOT
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "container_port" {
  description = "Port the container listens on and the target group forwards to."
  type        = number
  default     = 8080
}

variable "environment" {
  description = <<-EOT
    Plain (non-secret) environment variables for the container, as a name->value
    map. Secrets do NOT belong here — they leak in the task definition and the
    console; use var.secrets instead.
  EOT
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = <<-EOT
    Secret environment variables, as name -> Secrets Manager / SSM Parameter ARN.
    Injected via the task definition's `secrets` (valueFrom) so the value never
    appears in the definition. Grants the EXECUTION role GetSecretValue on
    exactly these ARNs.
  EOT
  type        = map(string)
  default     = {}
}

variable "container_health_check" {
  description = <<-EOT
    Optional container-level health check (Docker HEALTHCHECK). Null (default)
    relies solely on the target group health check.

    For a slow-starting model server, set start_period generously so the weight
    sync and warm-up do not count as failures.
  EOT
  type = object({
    command      = list(string)
    interval     = optional(number, 30)
    timeout      = optional(number, 5)
    retries      = optional(number, 3)
    start_period = optional(number, 300)
  })
  default = null
}

# --- Networking / placement --------------------------------------------------

variable "subnet_ids" {
  description = <<-EOT
    PRIVATE subnets for task placement. Tasks get no public IP; egress is via the
    NAT instance and AWS-service traffic via the VPC endpoints.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet is required."
  }
}

variable "security_group_ids" {
  description = "Security groups for the tasks. Normally just this service's own group."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "At least one security group is required."
  }
}

variable "assign_public_ip" {
  description = <<-EOT
    Give tasks a public IP. FALSE by design — these run in private subnets and
    reach AWS via endpoints/NAT. True would both expose them and add the IPv4
    hourly charge.
  EOT
  type        = bool
  default     = false
}

# --- Reachability: external target group OR service discovery -----------------
#
# This module does NOT own a target group. ECS refuses to create a service whose
# target group is not already associated with a load balancer, so ownership of
# the target group + listener rule belongs to the ALB side, and this module just
# attaches to a TG that already exists. Backend services skip the ALB entirely
# and use Cloud Map instead.

variable "target_group_arn" {
  description = <<-EOT
    ARN of an EXISTING target group — already associated with a load balancer
    (a listener/rule forwards to it) — to register tasks into. Empty (the
    default) means no load balancer.
  EOT
  type        = string
  default     = ""
}

variable "health_check_grace_period_seconds" {
  description = <<-EOT
    Seconds ECS ignores load-balancer health after a task starts. ONLY valid when
    target_group_arn is set (ECS rejects it otherwise), so it is passed through
    only in that case. Must exceed cold start. For service-discovery-only
    services the container health check's start_period plays this role instead.
  EOT
  type        = number
  default     = 300

  validation {
    condition     = var.health_check_grace_period_seconds >= 0
    error_message = "health_check_grace_period_seconds cannot be negative."
  }
}

variable "service_discovery_namespace_id" {
  description = <<-EOT
    Cloud Map private DNS namespace id (from networking/dns). When set, the module
    creates a Cloud Map service named app_name and registers the ECS tasks, so the
    service is reachable at <app_name>.<namespace>:<container_port> from any in-VPC
    client — no load balancer. Empty means no service discovery.

    Pair with a container_health_check on the readiness path: only tasks the check
    marks HEALTHY are registered in DNS, so callers never resolve a task whose
    models have not loaded.
  EOT
  type        = string
  default     = ""
}

variable "service_discovery_namespace_name" {
  description = "Namespace DNS suffix (e.g. genai-dev.internal), used only to build the service_fqdn output."
  type        = string
  default     = ""
}

# --- Observability -----------------------------------------------------------

variable "enable_alarms" {
  description = <<-EOT
    Create CloudWatch alarms on the service's CPU and memory utilization
    (AWS/ECS namespace, available without Container Insights). Off by default;
    turn on for anything worth watching.
  EOT
  type        = bool
  default     = false
}

variable "alarm_cpu_threshold" {
  description = "CPU utilization percent that trips the high-CPU alarm (sustained)."
  type        = number
  default     = 85
}

variable "alarm_memory_threshold" {
  description = <<-EOT
    Memory utilization percent that trips the high-memory alarm. A real OOM signal
    for a model server whose task size is a right-sizing question — a task that
    runs near this is a candidate to move up (or the image to slim down).
  EOT
  type        = number
  default     = 90
}

variable "alarm_actions" {
  description = <<-EOT
    SNS topic ARNs notified when an alarm fires (and clears). Empty means the
    alarm still exists and is visible/queryable, it just does not page anyone —
    wire an ops topic here when one exists.
  EOT
  type        = list(string)
  default     = []
}

# --- Logging / encryption ----------------------------------------------------

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch Logs retention. Set explicitly — the AWS default is "never
    expire", which accumulates cost silently.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 1
    error_message = "log_retention_days must be at least 1."
  }
}

variable "kms_key_arn" {
  description = "CMK encrypting the log group, and decrypting image layers, secrets and S3 objects the roles read."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

# --- IAM ---------------------------------------------------------------------

variable "permissions_boundary_arn" {
  description = "Permissions boundary applied to BOTH the task and execution roles. Required by the exec role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "ecr_repository_arns" {
  description = <<-EOT
    Repositories the EXECUTION role may pull from. ARN-scoped, so it cannot pull
    every image in the account. Empty grants no pull access.
  EOT
  type        = list(string)
  default     = []
}

variable "task_read_bucket_arns" {
  description = <<-EOT
    S3 bucket ARNs the TASK role may read (s3:GetObject + s3:ListBucket), e.g.
    the weights bucket. ARN-scoped; empty grants no S3 access. Both the bucket
    and its objects are covered — the module derives the /* object ARNs.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_execute_command" {
  description = <<-EOT
    Enable ECS Exec, the Fargate equivalent of Session Manager: it lets an
    operator open a shell in a running task (there is no SSH into Fargate).
    Grants the TASK role the ssmmessages channel actions. On by default for dev
    troubleshooting; a prod service may turn it off.
  EOT
  type        = bool
  default     = true
}

# --- Service / deployment ----------------------------------------------------

variable "desired_count" {
  description = <<-EOT
    Initial number of tasks. Note the service IGNORES later changes to this value
    (see the lifecycle block) so that Application Auto Scaling — not a stale
    Terraform value — owns capacity once scale-to-zero is enabled. Set the
    starting capacity here; scale it via autoscaling or the CLI thereafter.
  EOT
  type        = number
  default     = 1
}

variable "wait_for_steady_state" {
  description = <<-EOT
    Block `terraform apply` until the service reaches steady state (desired tasks
    running and healthy) rather than returning the moment the service object is
    created. With the deployment circuit breaker, a task that never becomes
    healthy fails the apply and rolls back — so a green apply MEANS a healthy
    service. Costs a few minutes of cold start on the apply; worth it for a
    first bring-up. Off by default to keep routine applies fast.
  EOT
  type        = bool
  default     = false
}

variable "use_fargate_spot" {
  description = <<-EOT
    Run tasks on FARGATE_SPOT (~70% cheaper) instead of on-demand FARGATE. Spot
    tasks can be reclaimed on a 2-minute notice, so a single-task service would
    see occasional interruption + cold-start replacement. Reasonable for a
    batch-tolerant dev workload; off by default so the first bring-up is stable.
  EOT
  type        = bool
  default     = false
}

variable "deployment_minimum_healthy_percent" {
  description = "Lower bound on healthy tasks during a deployment, as a percent of desired."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Upper bound on running tasks during a deployment, as a percent of desired."
  type        = number
  default     = 200
}

# --- Scheduled scale-to-zero -------------------------------------------------

variable "enable_autoscaling" {
  description = <<-EOT
    Register an Application Auto Scaling target on the service's DesiredCount and
    (if crons are set) scheduled scale up/down actions. OFF by default: the
    service is meant to land always-on first and prove healthy, THEN have the
    schedule added — a scale-to-zero applied before the service is verified would
    hide startup problems behind an off task.
  EOT
  type        = bool
  default     = false
}

variable "autoscaling_min_capacity" {
  description = "Minimum tasks the scalable target allows. 0 permits scale-to-zero."
  type        = number
  default     = 0
}

variable "autoscaling_max_capacity" {
  description = "Maximum tasks the scalable target allows."
  type        = number
  default     = 1
}

variable "scale_up_cron" {
  description = <<-EOT
    Schedule expression to scale UP (e.g. \"cron(0 11 ? * MON-FRI *)\"). Empty
    creates no up action. Interpreted in var.schedule_timezone.
  EOT
  type        = string
  default     = ""
}

variable "scale_down_cron" {
  description = "Schedule expression to scale DOWN to autoscaling_min_capacity. Empty creates no down action."
  type        = string
  default     = ""
}

variable "schedule_timezone" {
  description = "IANA timezone for the scheduled actions (e.g. UTC, America/New_York)."
  type        = string
  default     = "UTC"
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
