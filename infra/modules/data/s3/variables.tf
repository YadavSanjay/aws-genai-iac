variable "bucket_name" {
  description = <<-EOT
    Full bucket name. S3 names are GLOBALLY unique, so the caller supplies the
    whole thing rather than the module composing one from a short prefix — a
    silent collision with another account's bucket is a confusing failure.

    Convention here: <project>-<env>-<component>, e.g. aws-genai-iac-dev-logs.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase alphanumeric, dots and hyphens only, starting and ending alphanumeric."
  }

  validation {
    condition     = !can(regex("^xn--|--ol-s3$|\\.\\.", var.bucket_name))
    error_message = "bucket_name must not start with 'xn--', end with '--ol-s3', or contain consecutive dots."
  }
}

variable "kms_key_arn" {
  description = <<-EOT
    ARN (or alias ARN) of the CMK used for SSE-KMS. Required — there is no
    unencrypted path through this module.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "versioning_enabled" {
  description = <<-EOT
    Object versioning. Default on: it is the only protection against an
    accidental overwrite or delete, and noncurrent_expiration_days keeps the
    storage cost of old versions bounded.
  EOT
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = <<-EOT
    Allow `terraform destroy` to delete a non-empty bucket.

    Keep false for anything holding real data. NOTE: Terraform's
    `prevent_destroy` cannot be driven by a variable (it must be a literal), so
    this flag is the module's destroy guard — a false value makes destroy fail
    on a non-empty bucket rather than silently succeeding.
  EOT
  type        = bool
  default     = false
}

variable "expiration_days" {
  description = <<-EOT
    Delete current objects after this many days. 0 disables expiry.

    The provisioning principles require lifecycle on anything that accumulates,
    so leaving this at 0 needs a stated reason.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.expiration_days >= 0
    error_message = "expiration_days cannot be negative."
  }
}

variable "noncurrent_expiration_days" {
  description = "Delete noncurrent (superseded) versions after this many days."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_expiration_days > 0
    error_message = "noncurrent_expiration_days must be positive; unbounded old versions accumulate cost silently."
  }
}

variable "abort_incomplete_upload_days" {
  description = <<-EOT
    Abort incomplete multipart uploads after this many days. Orphaned parts are
    invisible in the console but billed as storage indefinitely — a classic
    silent cost leak.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_upload_days > 0
    error_message = "abort_incomplete_upload_days must be positive."
  }
}

variable "transitions" {
  description = <<-EOT
    Storage-class transitions, e.g. [{ days = 30, storage_class = "STANDARD_IA" }].

    Mind the minimums: STANDARD_IA bills a 30-day minimum, GLACIER_IR 90 days.
    Transitioning short-lived objects costs MORE than leaving them in Standard.
  EOT
  type = list(object({
    days          = number
    storage_class = string
  }))
  default = []

  validation {
    condition = alltrue([
      for t in var.transitions : contains(
        ["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"],
        t.storage_class
      )
    ])
    error_message = "Unknown storage_class in transitions."
  }
}

variable "access_log_bucket" {
  description = <<-EOT
    Bucket receiving S3 server access logs. Empty disables access logging.

    A bucket cannot log to itself, so the log-archive bucket at the root of the
    chain necessarily leaves this empty.
  EOT
  type        = string
  default     = ""
}

variable "access_log_prefix" {
  description = "Key prefix for delivered access logs."
  type        = string
  default     = ""
}

variable "allow_aws_log_delivery" {
  description = <<-EOT
    Add the bucket-policy statements AWS log delivery needs to write VPC flow
    logs, ALB access logs and similar into this bucket.

    A first-class flag rather than hand-built JSON via extra_policy_documents,
    because this is the common case and the statements are easy to get subtly
    wrong — in particular the s3:x-amz-acl condition that most published
    examples include is WRONG here, since BucketOwnerEnforced disables ACLs and
    the delivery service does not send that header.

    Objects land under AWSLogs/<account-id>/, which is what the PutObject grant
    is scoped to.
  EOT
  type        = bool
  default     = false
}

variable "extra_policy_documents" {
  description = <<-EOT
    Additional IAM policy JSON documents merged into the bucket policy.

    A bucket may have only ONE policy resource, so callers needing extra
    statements (e.g. allowing delivery.logs.amazonaws.com to write VPC flow
    logs) pass them here rather than attaching a second policy.
  EOT
  type        = list(string)
  default     = []
}

variable "restrict_encryption_header" {
  description = <<-EOT
    Deny PutObject that explicitly requests an encryption method other than
    aws:kms.

    Deliberately NOT the stricter "deny any upload without the SSE header":
    bucket default encryption already encrypts headerless uploads, and several
    AWS log-delivery services do not set the header. The strict form silently
    breaks them while adding nothing, since the object ends up KMS-encrypted
    either way.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
