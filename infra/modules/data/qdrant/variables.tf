variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    PRIVATE subnet for the Qdrant host.

    Pinned to a single subnet (us-east-1a in dev) so its data volume, the NAT
    instance and the consumer app hosts all sit in one AZ — every east-west
    vector query and ingest write is then same-AZ, i.e. $0 transfer. No public
    address; administered via SSM Session Manager only.
  EOT
  type        = string
}

variable "security_group_ids" {
  description = "Security groups to attach. Normally just the qdrant data-tier group."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "At least one security group is required; the VPC default is stripped to deny-all."
  }
}

variable "instance_type" {
  description = <<-EOT
    Instance type. Defaults to t4g.small — Graviton, 2 vCPU / 2 GB.

    The measured working set is ~204 MB (qdrant §2); t4g.small gives ~2x
    headroom for HNSW index builds and int8 optimization passes. arm64 only —
    the mirrored Qdrant image is linux/arm64. Move to t4g.medium on the §7 growth
    trigger, not up front.
  EOT
  type        = string
  default     = "t4g.small"
}

variable "root_volume_gb" {
  description = "Root volume: OS, Docker image store, no application data. Billed while stopped, so kept tight."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_gb >= 8
    error_message = "root_volume_gb must be at least 8."
  }
}

variable "data_volume_gb" {
  description = <<-EOT
    Dedicated EBS data volume for Qdrant storage + snapshots, separate from root.

    Separate so the vector data survives instance replacement (a user-data change
    replaces the instance; the data volume detaches and reattaches) and gets its
    own snapshot lifecycle. 20 GB is ample for the ~200 MB working set with
    snapshot room.
  EOT
  type        = number
  default     = 20

  validation {
    condition     = var.data_volume_gb >= 8
    error_message = "data_volume_gb must be at least 8."
  }
}

variable "kms_key_arn" {
  description = "CMK encrypting the root and data volumes, and decrypting the API-key secret."
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

variable "image" {
  description = <<-EOT
    Full ECR image reference the host pulls and runs, e.g.
    <acct>.dkr.ecr.<region>.amazonaws.com/genai-dev/qdrant:v1.18.2 or pinned by
    @sha256:<digest>. Mirrored in-account (never pulled from Docker Hub at boot).
  EOT
  type        = string
}

variable "ecr_repository_arns" {
  description = "Repositories the host may pull from. ARN-scoped — the qdrant repo only, not every repo in the account."
  type        = list(string)
  default     = []
}

variable "secret_arn" {
  description = <<-EOT
    ARN of the Secrets Manager secret holding {api_key}, read at boot to enforce
    the Qdrant API key.

    EMPTY ("") disables API-key auth — a deliberate, time-bounded dev bring-up
    relaxation (auth-off), documented in the README with its compensating
    controls (private subnet, SG-to-SG ingress only, no public IP, no real data).
    Set it to close the auth-off default before any real data lands, and always
    in prod. When empty, the instance role is granted no secret-read at all.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.secret_arn == "" || can(regex("^arn:aws:secretsmanager:", var.secret_arn))
    error_message = "secret_arn must be empty (auth-off) or a Secrets Manager ARN."
  }
}

variable "rest_port" {
  description = "Qdrant REST/HTTP port (TLS). Must match the SG rules."
  type        = number
  default     = 6333
}

variable "grpc_port" {
  description = "Qdrant gRPC port (TLS). Must match the SG rules."
  type        = number
  default     = 6334
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace id. The host registers as qdrant.<namespace> for in-VPC consumers."
  type        = string
}

variable "service_discovery_namespace_name" {
  description = "Cloud Map namespace name (e.g. genai-dev.internal), used to build the discovery DNS name and the TLS cert CN."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
