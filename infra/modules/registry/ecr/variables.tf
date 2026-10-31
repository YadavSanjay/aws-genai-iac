variable "repositories" {
  description = <<-EOT
    Repository names to create, e.g. ["genai-dev/macrorag"].

    ECR names are per account and region, so they carry the environment prefix
    themselves rather than relying on a separate namespace.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.repositories) > 0
    error_message = "At least one repository is required."
  }

  validation {
    condition = alltrue([
      for r in var.repositories : can(regex("^[a-z0-9][a-z0-9._/-]{1,255}$", r))
    ])
    error_message = "Repository names must be lowercase alphanumeric with . _ / - and start alphanumeric."
  }
}

variable "kms_key_arn" {
  description = "CMK for image-layer encryption at rest. Required — there is no unencrypted path."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "image_tag_mutability" {
  description = <<-EOT
    IMMUTABLE or MUTABLE.

    IMMUTABLE is the default and the secure choice: a tag, once pushed, cannot
    be repointed at different content. That closes the window where an audited
    image tag is quietly replaced, and it makes a deployed tag a reliable
    record of what is running.

    The cost is that `:latest` stops working as a rolling tag — images must
    carry a distinct tag per build, typically the git SHA. That is better
    practice regardless, but it does mean a push workflow relying on `:latest`
    must change.
  EOT
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }
}

variable "scan_on_push" {
  description = <<-EOT
    Run ECR basic vulnerability scanning on every push.

    Basic scanning is free. Enhanced scanning (Inspector) is not, and is not
    enabled here.
  EOT
  type        = bool
  default     = true
}

variable "keep_tagged_images" {
  description = <<-EOT
    Number of tagged images to retain per repository.

    Layers are shared between builds, so N versions cost far less than N times
    one image — but retention still needs a bound, or the repository grows
    forever at $0.10/GB-month.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.keep_tagged_images >= 1
    error_message = "keep_tagged_images must be at least 1."
  }
}

variable "untagged_expiry_days" {
  description = <<-EOT
    Days before an untagged image is deleted.

    Untagged images are the residue of overwritten or failed pushes. Nothing
    references them, and without this rule they accumulate silently.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.untagged_expiry_days >= 1
    error_message = "untagged_expiry_days must be at least 1."
  }
}

variable "force_delete" {
  description = <<-EOT
    Allow `terraform destroy` to delete a repository still containing images.

    False by default, so a destroy fails loudly rather than silently discarding
    the only copy of an image.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
