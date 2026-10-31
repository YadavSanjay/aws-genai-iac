variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR."
  }

  validation {
    condition     = tonumber(split("/", var.cidr_block)[1]) <= 24
    error_message = "cidr_block must be /24 or larger — a smaller VPC cannot be split across AZs."
  }
}

variable "enable_dns_support" {
  description = "Resolve DNS via the Amazon-provided resolver. Required for VPC endpoints and private hosted zones."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Assign DNS hostnames to instances. Required for private hosted zones and several AWS services."
  type        = bool
  default     = true
}

variable "create_internet_gateway" {
  description = <<-EOT
    Attach an Internet Gateway.

    Free, and attaching one exposes nothing by itself — reachability also needs
    a route table entry, a public subnet and a permissive security group. It is
    a prerequisite for the NAT Gateway that private subnets egress through.
  EOT
  type        = bool
  default     = true
}

# --- Flow logs ---------------------------------------------------------------

variable "flow_log_destination_arn" {
  description = <<-EOT
    S3 bucket ARN receiving flow logs. Empty disables flow logging.

    The bucket must already permit delivery.logs.amazonaws.com to write, and if
    it is SSE-KMS the key policy must permit that principal too. A missing KMS
    grant does not fail loudly: the flow log reports ACTIVE and silently
    delivers nothing.
  EOT
  type        = string
  default     = ""
}

variable "flow_log_traffic_type" {
  description = <<-EOT
    Which traffic to record: ALL, ACCEPT or REJECT.

    ALL is the useful default at dev volume. REJECT-only is materially cheaper
    on a busy VPC while still carrying most security-relevant signal, so it is
    worth revisiting before prod.
  EOT
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ALL", "ACCEPT", "REJECT"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ALL, ACCEPT or REJECT."
  }
}

variable "flow_log_max_aggregation_interval" {
  description = <<-EOT
    Seconds over which flows are aggregated before publishing: 60 or 600.

    600 produces fewer, larger objects — cheaper to store and to query — at the
    cost of coarser timing. 60 is worth it only while investigating something
    live.
  EOT
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.flow_log_max_aggregation_interval)
    error_message = "flow_log_max_aggregation_interval must be 60 or 600."
  }
}

variable "flow_log_file_format" {
  description = <<-EOT
    plain-text or parquet.

    Parquet is roughly 20% smaller on ingest and dramatically cheaper to query
    with Athena, being columnar and able to skip irrelevant fields.
  EOT
  type        = string
  default     = "parquet"

  validation {
    condition     = contains(["plain-text", "parquet"], var.flow_log_file_format)
    error_message = "flow_log_file_format must be plain-text or parquet."
  }
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
