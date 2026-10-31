variable "name_prefix" {
  description = "Prefix applied to resource names and tags (e.g. genai-dev)."
  type        = string
}

variable "namespace_name" {
  description = <<-EOT
    Private DNS namespace, e.g. genai-dev.internal. Backend services register a
    record under it, so a task is reachable at <service>.<namespace> — e.g.
    raginference.genai-dev.internal — with no load balancer in the path.

    Not a public/registered domain: it resolves ONLY inside the VPC, via the
    Route53 private hosted zone this namespace creates.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.namespace_name))
    error_message = "namespace_name must be a lowercase DNS name (letters, digits, dots, hyphens)."
  }
}

variable "vpc_id" {
  description = "VPC the private hosted zone is associated with — the only place the namespace resolves."
  type        = string
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
