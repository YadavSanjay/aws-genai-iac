variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC to attach the endpoint to."
  type        = string
}

variable "region" {
  description = "Region — used to build the endpoint service name."
  type        = string
}

variable "route_table_ids" {
  description = <<-EOT
    Route tables that should route S3 traffic through the gateway endpoint.

    Pass every table whose subnets talk to S3. A gateway endpoint works by
    injecting a prefix-list route, so a table not listed here keeps sending S3
    traffic the long way — through NAT, at $0.045/GB.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.route_table_ids) > 0
    error_message = "At least one route table is required, or the endpoint routes nothing."
  }
}

variable "writable_bucket_arns" {
  description = <<-EOT
    Bucket ARNs this VPC may WRITE to through the endpoint. Everything else is
    read-only — see the note in main.tf on why that split is the useful one.

    Supply bucket ARNs without the /* suffix; the module adds object-level ARNs.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.writable_bucket_arns) > 0
    error_message = "At least one writable bucket is required, or nothing in the VPC can write to S3."
  }

  validation {
    condition     = alltrue([for a in var.writable_bucket_arns : !endswith(a, "/*")])
    error_message = "Supply bucket ARNs without the /* suffix — object ARNs are derived."
  }
}

variable "restrict_endpoint_policy" {
  description = <<-EOT
    Apply the scoped endpoint policy. When false the endpoint keeps AWS's
    default full-access policy.

    Only set false to diagnose a suspected endpoint-policy problem — and put it
    back.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
