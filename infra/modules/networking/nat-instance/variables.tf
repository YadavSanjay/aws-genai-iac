variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the instance lives in."
  type        = string
}

variable "public_subnet_id" {
  description = <<-EOT
    Public subnet hosting the instance. It must have a default route to an
    Internet Gateway, or the NAT has nowhere to forward to.
  EOT
  type        = string
}

variable "private_route_table_ids" {
  description = <<-EOT
    Private route tables that should send 0.0.0.0/0 through this instance.

    Prefer the route tables in the SAME AZ as public_subnet_id. Cross-AZ traffic
    to a NAT device is billed at $0.01/GB in each direction, which can quietly
    exceed the instance cost.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.private_route_table_ids) > 0
    error_message = "At least one private route table is required, or nothing egresses through this instance."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDRs permitted to send traffic through the NAT. Normally the private subnets."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) > 0
    error_message = "At least one source CIDR is required."
  }

  validation {
    condition     = alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "private_subnet_cidrs must all be valid IPv4 CIDRs."
  }
}

variable "instance_type" {
  description = <<-EOT
    Instance type. Defaults to t4g.nano — Graviton, ~$3.07/month on demand.

    Sizing is about BANDWIDTH, not CPU: NAT is packet forwarding, which is
    nearly free computationally. t4g.nano sustains ~32 Mbps baseline with burst
    to ~5 Gbps, which comfortably covers LLM API calls (small payloads) and
    container pulls (which bypass NAT entirely via the S3 gateway endpoint).

    Move up only on measured throughput, not intuition.
  EOT
  type        = string
  default     = "t4g.nano"
}

variable "permissions_boundary_arn" {
  description = <<-EOT
    Permissions boundary applied to the instance role.

    Required: the exec role may only create roles that carry the project
    boundary, so omitting this makes CreateRole fail.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "kms_key_arn" {
  description = "CMK encrypting the root EBS volume."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS ARN."
  }
}

variable "root_volume_gb" {
  description = "Root volume size. The NAT does nothing but forward packets; 8 GB is ample."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_gb >= 8
    error_message = "root_volume_gb must be at least 8 (the AL2023 image minimum)."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
