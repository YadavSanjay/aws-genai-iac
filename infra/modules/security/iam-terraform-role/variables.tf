variable "name_prefix" {
  description = "Prefix for all IAM resources this module creates (e.g. genai). The prefix also scopes what the exec role is allowed to manage: role/<prefix>-*."
  type        = string
  default     = "genai"
}

variable "account_id" {
  description = "AWS account id the resources live in. Used to build ARNs and the default trust principal."
  type        = string
}

variable "region" {
  description = "Region the exec role is allowed to operate in (aws:RequestedRegion lock on regional services)."
  type        = string
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform remote state (created out-of-band by scripts/bootstrap-backend.sh)."
  type        = string
}

variable "trusted_principal_arns" {
  description = <<-EOT
    Principals allowed to sts:AssumeRole into the exec role — e.g. your IAM Identity Center
    permission-set role ARN, or a thin tfuser ARN. Leave empty and the trust uses the
    auto-added tfuser (when create_terraform_user + assume-role mode). Only when there is NO
    explicit principal AND NO tfuser does the trust fall back to the account root (any account
    principal with sts:AssumeRole) — a fallback the module permits only when require_mfa = true.
    Set explicit ARNs for anything beyond a solo dev box.
  EOT
  type        = list(string)
  default     = []
}

variable "require_mfa" {
  description = "Require aws:MultiFactorAuthPresent on the AssumeRole trust policy."
  type        = bool
  default     = true
}

variable "max_session_seconds" {
  description = "Maximum STS session duration for the exec role."
  type        = number
  default     = 3600
}

variable "create_terraform_user" {
  description = "Create a dedicated IAM user for Terraform work (instead of / in addition to using an SSO or admin identity). Access keys are NOT created here — mint them with `aws iam create-access-key` to keep secrets out of state."
  type        = bool
  default     = false
}

variable "terraform_user_name" {
  description = "Name of the Terraform IAM user when create_terraform_user = true."
  type        = string
  default     = "tfuser"
}

variable "user_access_mode" {
  description = <<-EOT
    How the Terraform user gets its permissions:
      * "assume-role"   (recommended) — user holds ONLY sts:AssumeRole onto the exec
        role; scoped power stays on the role, credentials are short-lived. The user
        is auto-added to the exec role trust policy.
      * "direct-attach" — the five scoped policies are attached straight to the user;
        simplest `--profile tfuser` flow, but the user's long-lived keys carry the
        full scoped power. No role assumption needed.
  EOT
  type        = string
  default     = "assume-role"
  validation {
    condition     = contains(["assume-role", "direct-attach"], var.user_access_mode)
    error_message = "user_access_mode must be \"assume-role\" or \"direct-attach\"."
  }
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
