variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "app_name" {
  description = "Subsystem name for this runner (e.g. arag-ingest). Full name is <name_prefix>-<app_name>."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet the runner launches into."
  type        = string
}

variable "security_group_ids" {
  description = <<-EOT
    Security groups for the runner. Reuse the app tier's SG: it already egresses to
    RDS, the shared Qdrant, RagInference, and 443 (EDGAR + OpenAI + AWS APIs), which
    is exactly the ingest's outbound set. No inbound — access is SSM only.
  EOT
  type        = list(string)
}

variable "instance_type" {
  description = <<-EOT
    Instance class. Graviton (arm64). The runner ORCHESTRATES the ingest — Arelle
    parses iXBRL locally, but embeddings are offloaded to RagInference — so memory
    (Arelle) matters more than vCPU. t4g.medium (4 GB) is a safe default; bump for a
    large bulk ingest, then drop back (like the RagInference vCPU bump).
  EOT
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_gb" {
  description = <<-EOT
    Root gp3 volume. Sized for scratch, not persistence: S3FilingStore.localize_dir()
    downloads filing dirs to a temp workdir for Arelle, then cleans up. Filings live
    durably on S3, so this is ephemeral working space.
  EOT
  type        = number
  default     = 40
}

variable "kms_key_arn" {
  description = "CMK for the encrypted root volume, and for the role's Decrypt-via-service grant."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to the runner's role (the app boundary)."
  type        = string
}

variable "image_pointer_uri" {
  description = <<-EOT
    S3 URI of the object naming the image to run, as a single KEY=value line:
    ARAG_INGEST_IMAGE=<registry>/genai-dev/arag-ingest:arm64-<sha>

    Deliberately a POINTER, not the image URI itself. The URI would land in
    user_data, and this instance carries user_data_replace_on_change, so bumping
    an image would replace the box. The runner reads this object at run time
    instead; publish a new tag with scripts/deploy_arag_ingest_image.py.

    Must live in a bucket the runner's role can s3:GetObject (the filings bucket
    already qualifies via s3_bucket_arns — no extra grant needed).
  EOT
  type        = string

  validation {
    condition     = startswith(var.image_pointer_uri, "s3://")
    error_message = "image_pointer_uri must be an s3:// URI — it is fetched with `aws s3 cp`."
  }
}

variable "ecr_repository_arns" {
  description = "ECR repositories the runner may pull. ARN-scoped — its own ingest image only."
  type        = list(string)
}

variable "secret_arns" {
  description = "Secrets the runner reads (its app secret). ARN-scoped."
  type        = list(string)
  default     = []
}

variable "db_secret_arn" {
  description = <<-EOT
    Optional JSON DB secret (RDS-managed) whose fields are written into the runtime
    env-file under db_secret_env_map names. The read grant is added automatically.
  EOT
  type        = string
  default     = ""
}

variable "db_secret_env_map" {
  description = "Maps db_secret_arn JSON keys to env-var names (e.g. username -> XBRL_DB_USER)."
  type        = map(string)
  default = {
    username = "DB_USERNAME"
    password = "DB_PASSWORD"
  }
}

variable "s3_bucket_arns" {
  description = <<-EOT
    Buckets the runner may read AND write. The ingest DOWNLOADS filings from EDGAR
    and writes them (attachments, manifest.yaml, canonical HTML) to the filings
    bucket — so this is read+write, unlike the app tier's read-only bundle grant.
  EOT
  type        = list(string)
  default     = []
}

variable "runtime_env" {
  description = <<-EOT
    Non-secret env written to /opt/app/.env, passed to the ingest container. Endpoints
    + deploy mode (ARAG_DEPLOY_MODE=aws, XBRL_DB_HOST/PORT/NAME, QDRANT_*, RAGINFER_URL,
    ARAG_S3_BUCKET, ...). NEVER credentials — those come from app_env_secret_arn / db_secret_arn.
  EOT
  type        = map(string)
  default     = {}
}

variable "app_env_secret_arn" {
  description = "Secret rendered VERBATIM (KEY=value lines) to app_env_file_path. Empty means none."
  type        = string
  default     = ""
}

variable "app_env_file_path" {
  description = "Host path the app_env_secret_arn value renders to (mode 600), and where DB_* are appended."
  type        = string
  default     = "/opt/arag/.env"
}

variable "imds_hop_limit" {
  description = <<-EOT
    IMDS PUT hop limit. The ingest CONTAINER runs boto3 (S3 FilingStore) and reaches
    the instance role THROUGH the docker bridge — one hop past the host — so this is 2.
    The role is tightly ARN-scoped, the compensating control for the extra hop.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 64
    error_message = "imds_hop_limit must be between 1 and 64."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
