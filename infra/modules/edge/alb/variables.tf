variable "enabled" {
  description = <<-EOT
    THE SWITCH. When false, NO load balancer, listener or target group exists —
    the module creates nothing billable and applications are reachable only via
    SSM port forwarding.

    An ALB cannot be stopped the way an EC2 instance can. It bills $16.43/month
    for every month it exists, regardless of traffic, so "off" has to mean
    "destroyed". Driven by ingress_mode in the environment's env.hcl.

    Flipping this to false and applying is a normal, safe operation: the
    security groups are untouched (they are free and referenced by the app
    tier), so flipping back recreates only the load balancer.
  EOT
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the target groups."
  type        = string
}

variable "private_subnet_ids" {
  description = <<-EOT
    Subnets for the load balancer nodes. At least two, in different AZs — AWS
    rejects an ALB in a single AZ.

    Named for the intended use: this ALB is internal, so it belongs in the
    private subnets. An internet-facing ALB would need public ones.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "An ALB requires at least two subnets in different availability zones."
  }
}

variable "security_group_id" {
  description = "ALB security group, from networking/security-groups."
  type        = string
}

variable "targets" {
  description = <<-EOT
    Applications behind the load balancer, keyed by name.

    - instance_id       EC2 instance to register
    - port              Port the application listens on
    - health_check_path Path returning 200 when healthy
    - path_patterns     Listener-rule paths, e.g. ["/macrorag", "/macrorag/*"].
                        Empty means this target is the DEFAULT action.
    - priority          Listener rule priority (lower wins). Ignored when
                        path_patterns is empty.

    Exactly one target must have empty path_patterns — the ALB needs a default
    action for requests matching no rule.
  EOT
  type = map(object({
    instance_id       = string
    port              = number
    health_check_path = optional(string, "/")
    path_patterns     = optional(list(string), [])
    priority          = optional(number, 100)
  }))
  default = {}

  validation {
    condition     = length([for t in var.targets : t if length(t.path_patterns) == 0]) <= 1
    error_message = "At most one target may have empty path_patterns — only one can be the default action."
  }
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for the HTTPS listener. Empty means NO certificate, so the
    listener is plain HTTP on port 80 and traffic is unencrypted.

    A certificate requires a registered domain (ACM validates by DNS or email),
    which is why this is empty today.
  EOT
  type        = string
  default     = ""
}

variable "internal" {
  description = <<-EOT
    Internal (VPC-only) rather than internet-facing. Defaults to TRUE.

    Internal is the safer default and the right one for east-west traffic: the
    load balancer resolves to private addresses, so in-VPC clients reach it
    directly. An internet-facing ALB cannot serve in-VPC callers reliably —
    they egress through NAT and arrive with its public source address, which is
    auto-assigned and changes on restart.
  EOT
  type        = bool
  default     = true
}

variable "idle_timeout_seconds" {
  description = <<-EOT
    Seconds an idle connection is held open.

    The 60-second default is too short for RAG workloads: a single LLM-backed
    request can legitimately take longer, and the ALB returns 504 while the
    application is still working — which reads like an application timeout.
  EOT
  type        = number
  default     = 120

  validation {
    condition     = var.idle_timeout_seconds >= 1 && var.idle_timeout_seconds <= 4000
    error_message = "idle_timeout_seconds must be between 1 and 4000."
  }
}

variable "access_logs_bucket" {
  description = "Bucket for ALB access logs. Empty disables access logging."
  type        = string
  default     = ""
}

variable "deletion_protection" {
  description = <<-EOT
    Block deletion of the load balancer.

    MUST stay false here: the whole point of the ingress switch is that
    `ingress_mode = "ssm"` destroys the ALB. Enable it in prod, where the ALB is
    permanent.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
