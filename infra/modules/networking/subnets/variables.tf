variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create subnets in."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the VPC. Subnet ranges are carved from this."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "internet_gateway_id" {
  description = <<-EOT
    IGW for the public route table's default route. Empty means no default
    route is created, leaving public subnets isolated — useful for validating
    that nothing depends on internet reachability yet.
  EOT
  type        = string
  default     = ""
}

variable "az_count" {
  description = <<-EOT
    Number of availability zones to spread across.

    Two is the minimum for any HA story and the right default. Note the cost
    asymmetry: subnets and route tables are free, so AZ count costs nothing
    here — it is NAT, load balancers and data transfer that scale per-AZ.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "subnet_newbits" {
  description = <<-EOT
    Bits added to the VPC prefix when carving subnets. With a /16 VPC, 4 gives
    /20 subnets (4,091 usable addresses each) — ample, while leaving most of the
    VPC unallocated for future tiers.
  EOT
  type        = number
  default     = 4

  validation {
    condition     = var.subnet_newbits >= 1 && var.subnet_newbits <= 12
    error_message = "subnet_newbits must be between 1 and 12."
  }
}

variable "private_subnet_offset" {
  description = <<-EOT
    Index offset at which private subnet ranges begin, keeping them in a clearly
    separate block from public ones.

    With the default newbits of 4 (16 possible /20s), offset 8 puts public at
    indices 0..n and private at 8..8+n — so 10.10.0.0/20 upward is public and
    10.10.128.0/20 upward is private. Readable at a glance in a route table.
  EOT
  type        = number
  default     = 8
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
