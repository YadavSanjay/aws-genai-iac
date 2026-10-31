variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "app_name" {
  description = "Application this instance hosts, e.g. macrorag. Used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,32}$", var.app_name))
    error_message = "app_name must be lowercase alphanumeric with hyphens."
  }
}

variable "subnet_id" {
  description = <<-EOT
    PRIVATE subnet for the instance.

    Reachability comes from the ALB, and outbound from the NAT instance. An
    instance here has no public address and cannot be reached directly.
  EOT
  type        = string
}

variable "security_group_ids" {
  description = "Security groups to attach. Normally just the app tier group."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "At least one security group is required; the VPC default is stripped to deny-all."
  }
}

variable "instance_type" {
  description = <<-EOT
    Instance type. Defaults to t4g.large — Graviton, 2 vCPU / 8 GB.

    arm64 is ~20% cheaper than the x86 equivalent for the same performance, but
    ONLY works if the container image is built for arm64. A mismatched image
    fails at container start with "exec format error", which is easy to
    misread as a corrupt image.
  EOT
  type        = string
  default     = "t4g.large"
}

variable "root_volume_gb" {
  description = <<-EOT
    Root volume size. Holds the OS, container images and any local application
    state (MacroRAG keeps SQLite on disk).

    Billed even while the instance is stopped, so this is the floor of the
    instance's monthly cost — keep it tight.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_gb >= 8
    error_message = "root_volume_gb must be at least 8."
  }
}

variable "data_volume_gb" {
  description = <<-EOT
    Size of a dedicated EBS data volume attached at /dev/sdf, separate from the
    root. 0 (default) creates no data volume, so consumers that do not need one
    are unaffected.

    Use it for state that must survive INSTANCE REPLACEMENT (an AMI refresh or
    an instance-type change), not merely a stop/start — the root volume survives
    a stop/start but is deleted on termination. MacroRAG keeps its SQLite stores
    (timeseries + ingest cache), traces and eval here.

    CMK-encrypted, lands in the instance's AZ. Formatting and mounting are the
    bootstrap's job (mount by LABEL, so NVMe device renaming across a stop/start
    cannot break the mount) — this only creates and attaches it.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.data_volume_gb >= 0
    error_message = "data_volume_gb cannot be negative; 0 disables the data volume."
  }
}

variable "kms_key_arn" {
  description = "CMK encrypting the root and data volumes, and decrypting secrets and image layers."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the instance role. Required by the exec role."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "ecr_repository_arns" {
  description = <<-EOT
    Repositories this instance may pull from. ARN-scoped, so the role cannot
    pull every image in the account.

    Empty grants no pull access at all.
  EOT
  type        = list(string)
  default     = []
}

variable "secret_arns" {
  description = <<-EOT
    Secrets this instance may read. ARN-scoped for the same reason.

    Empty grants no secret access at all.
  EOT
  type        = list(string)
  default     = []
}

variable "s3_bucket_arns" {
  description = <<-EOT
    Buckets this instance may read AND write. ARN-scoped: the role gets object
    CRUD (Get/Put/Delete) on their contents plus ListBucket on the buckets
    themselves — not every bucket in the account.

    Object encryption uses the CMK in kms_key_arn; the DecryptViaServices grant
    below already covers the s3 ViaService path, so no extra KMS wiring is
    needed. boto3 obtains credentials from the instance role — no keys on disk.

    Empty grants no S3 access at all.
  EOT
  type        = list(string)
  default     = []
}

variable "bundle_read_bucket_arn" {
  description = <<-EOT
    Bucket the bootstrap may READ (ListBucket + GetObject) to fetch the deploy
    bundle, when the bundle does not live in an s3_bucket_arns bucket. Read-only
    and separate from s3_bucket_arns deliberately: a host whose app has no data
    bucket (a stateless tier) still needs to pull its compose bundle, but must not
    get write access to do it. Empty means the bundle rides an s3_bucket_arns
    grant (the MacroRAG case, whose bundle sits in its RW corpus bucket).
  EOT
  type        = string
  default     = ""
}

variable "imds_hop_limit" {
  description = <<-EOT
    IMDSv2 PUT-response hop limit. Default 1: a container on this host CANNOT
    reach instance metadata, which closes the standard container-escape-to-
    instance-role path.

    Set to 2 ONLY when a container legitimately needs the instance role at
    runtime — e.g. a boto3 workload reading S3/Secrets Manager through the
    Docker bridge (one extra hop). The compensating control is that the instance
    role is tightly ARN-scoped, so a container assuming it gains only what the
    app already needs.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 2
    error_message = "imds_hop_limit must be 1 (host only) or 2 (containers may reach the instance role)."
  }
}

variable "compose_bundle_s3_uri" {
  description = <<-EOT
    S3 URI (s3://bucket/prefix) of the deploy bundle — the docker compose file
    and its config files. The per-boot deploy `aws s3 sync`s it to the host and
    runs `docker compose up`. Empty (default) means docker-runtime only: the
    host installs Docker + Compose + the AWS CLI and starts nothing.
  EOT
  type        = string
  default     = ""
}

variable "compose_file_relpath" {
  description = <<-EOT
    Path to the compose file WITHIN the synced bundle, e.g.
    "infra/docker/docker-compose.aws.yml". Compose resolves the file's relative
    volume mounts (../config, ../otel) against this location, so the bundle must
    preserve that layout.
  EOT
  type        = string
  default     = ""
}

variable "runtime_env" {
  description = <<-EOT
    Non-secret, HOST-STATIC environment for compose interpolation — service
    endpoints, bucket names, the secret env-file path. Written to /opt/app/.env
    (part of user-data), so changing it REPROVISIONS the instance. Keep only
    values that change rarely here; put churny values (image tags) in deploy_env.
    NEVER put credentials here; use app_env_secret_arn for those.
  EOT
  type        = map(string)
  default     = {}
}

variable "deploy_env_relpath" {
  description = <<-EOT
    Path WITHIN the synced bundle to a per-deploy compose env-file (principally
    the image tags), e.g. "deploy.env". app-deploy.sh passes it as a second
    compose --env-file, so its values override the host-static placeholders in
    /opt/app/.env.

    The point: it lives in the S3 bundle, NOT user-data — so bumping an image is
    "re-upload the bundle + `systemctl restart app.service`", with no instance
    replacement and no IAM change (the role already reads the bundle from S3).
    Empty means no second env-file.
  EOT
  type        = string
  default     = ""
}

variable "app_env_secret_arn" {
  description = <<-EOT
    Secret whose value is rendered VERBATIM to app_env_file_path at each boot,
    to be consumed as a compose `env_file`. The value must therefore be stored
    as KEY=value lines, not JSON. Empty means no secret env-file is written.

    Must also appear in secret_arns for the IAM read grant.
  EOT
  type        = string
  default     = ""
}

variable "app_env_file_path" {
  description = <<-EOT
    Host path the app_env_secret_arn value is rendered to (mode 600). Must match
    the compose service's `env_file:` path. Ignored when app_env_secret_arn is
    empty.
  EOT
  type        = string
  default     = "/opt/app/secret.env"
}

variable "db_secret_arn" {
  description = <<-EOT
    Optional JSON secret (e.g. an RDS-managed master-user secret) whose fields are
    exported as DB_* env vars into a SEPARATE env-file (mode 600) at each boot, for
    the compose stack to consume as a second `env_file`. Distinct from
    app_env_secret_arn: that one is rendered verbatim (KEY=value lines); this one is
    parsed from JSON — username->DB_USERNAME, password->DB_PASSWORD, and host/port/
    dbname->DB_HOST/DB_PORT/DB_NAME when present.

    Because the fetch happens per-boot in app-deploy.sh, a rotated credential is
    picked up by `systemctl restart app.service` — no image rebuild, no reprovision.

    The read grant is added automatically; it need NOT also appear in secret_arns.
    Empty means no DB env-file is written.
  EOT
  type        = string
  default     = ""
}

variable "db_secret_env_map" {
  description = <<-EOT
    Maps db_secret_arn JSON keys to the env-var names written into the app env-file
    (only used when db_secret_arn is set). The consumer chooses names its code
    already expects, so no in-container or compose-level remapping is needed — e.g.
    { username = "XBRL_DB_USER", password = "XBRL_DB_PASSWORD" } for an app that
    reads XBRL_DB_*. Keys absent from the secret are skipped. Defaults to generic
    DB_* names for an RDS-managed {username,password[,host,port,dbname]} secret.
  EOT
  type        = map(string)
  default = {
    username = "DB_USERNAME"
    password = "DB_PASSWORD"
    host     = "DB_HOST"
    port     = "DB_PORT"
    dbname   = "DB_NAME"
  }
}

variable "data_mount_point" {
  description = <<-EOT
    Filesystem path the data volume mounts at (by LABEL). Must match the path the
    compose stack mounts for durable state. Only used when data_volume_gb > 0.
  EOT
  type        = string
  default     = "/mnt/data"
}

variable "start_cron" {
  description = <<-EOT
    EventBridge Scheduler cron (6-field) that STARTS this host. Empty (default)
    creates no schedule, so a tier that must stay up is unaffected.

    Scheduling lives HERE, in the same state as the instance, for the same reason
    service discovery does: a separate `*-schedule` component holds a COPY of the
    instance id, and re-applying the host without also re-applying that component
    leaves the schedule pointing at a terminated instance. Here it is a
    REFERENCE, so a replacement rewrites the target in the same apply.

    Requires stop_cron; the pair is set together or not at all.
  EOT
  type        = string
  default     = ""
}

variable "stop_cron" {
  description = "Cron that STOPS this host. See start_cron; the two go together."
  type        = string
  default     = ""
}

variable "schedule_timezone" {
  description = <<-EOT
    IANA timezone the crons are read in. Load-bearing: an IANA name (not a fixed
    offset) keeps the local window stable across daylight saving.
  EOT
  type        = string
  default     = "America/New_York"
}

variable "schedule_enabled" {
  description = <<-EOT
    Master switch for the pair. false disables BOTH — the stop AND the start — so
    a host turned off for a one-night override does not come back on its own.
  EOT
  type        = bool
  default     = true
}

variable "service_discovery_namespace_id" {
  description = <<-EOT
    Cloud Map private DNS namespace to register this host in, making it
    resolvable in-VPC at <discovery_service_name>.<namespace>. Empty (default)
    registers nothing — a tier only its own users reach over an SSM tunnel needs
    no name.

    Registration lives HERE, in the same state as the instance, deliberately.
    The A record's value references aws_instance.app.private_ip, so replacing the
    instance updates the record in the SAME apply; a separate component holding
    the same value would go stale the moment this one was re-applied without it,
    which is exactly how the app-schedule components orphan themselves. A VPC
    instance also keeps its private address across stop/start, so a scheduled
    tier does not churn its record daily.
  EOT
  type        = string
  default     = ""
}

variable "service_discovery_namespace_name" {
  description = <<-EOT
    DNS suffix of that namespace (e.g. genai-dev.internal). Required alongside
    service_discovery_namespace_id, and enforced by a precondition rather than
    left to produce a quietly-empty discovery_fqdn output. The namespace id
    cannot be resolved back to its name by any data source, so it is passed
    explicitly; the dns component emits both.
  EOT
  type        = string
  default     = ""
}

variable "discovery_service_name" {
  description = <<-EOT
    Left-most DNS label to register under the namespace (e.g. "arag" ->
    arag.genai-dev.internal). Defaults to app_name. Only used when
    service_discovery_namespace_id is set.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
