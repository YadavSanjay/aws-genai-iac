variable "name_prefix" {
  description = "Prefix applied to resource names (e.g. genai-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — used to scope intra-VPC egress such as DNS."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "app_port" {
  description = <<-EOT
    TCP port the application tier listens on for ALB traffic.

    A single port, not a range: the ALB is the only thing that may reach the app
    tier, and it targets one port per listener rule.
  EOT
  type        = number
  default     = 8000

  validation {
    condition     = var.app_port > 0 && var.app_port <= 65535
    error_message = "app_port must be a valid TCP port."
  }
}

variable "raginfer_port" {
  description = <<-EOT
    TCP port the RagInference (Fargate) service listens on for ALB traffic.

    A distinct service tier from the app_port app hosts: RagInference is a shared
    model server other subsystems call THROUGH the internal ALB, so its group
    admits the ALB on this one port and nothing else.
  EOT
  type        = number
  default     = 8799

  validation {
    condition     = var.raginfer_port > 0 && var.raginfer_port <= 65535
    error_message = "raginfer_port must be a valid TCP port."
  }
}

variable "qdrant_rest_port" {
  description = <<-EOT
    TCP port the shared Qdrant vector store serves its REST API on (default 6333).

    A distinct data tier: Qdrant is reached DIRECTLY by its consumers (the app
    tier, and later the ARag ingest job-runner) over the VPC, not through the
    ALB. Its group admits those consumer groups on this port and 6334, nothing
    else. See docs/design/qdrant-cloud-vs-self-hosted.md §6a.
  EOT
  type        = number
  default     = 6333

  validation {
    condition     = var.qdrant_rest_port > 0 && var.qdrant_rest_port <= 65535
    error_message = "qdrant_rest_port must be a valid TCP port."
  }
}

variable "qdrant_grpc_port" {
  description = "TCP port the shared Qdrant vector store serves gRPC on (default 6334). Same access pattern as qdrant_rest_port."
  type        = number
  default     = 6334

  validation {
    condition     = var.qdrant_grpc_port > 0 && var.qdrant_grpc_port <= 65535
    error_message = "qdrant_grpc_port must be a valid TCP port."
  }
}

variable "rds_port" {
  description = <<-EOT
    TCP port the ARag RDS PostgreSQL instance listens on (default 5432).

    A distinct data tier: the DB is reached DIRECTLY by its consumers (the app
    tier, and later the ARag ingest job-runner) over the VPC, not through the
    ALB. Its group admits those consumer groups on this port and nothing else.
  EOT
  type        = number
  default     = 5432

  validation {
    condition     = var.rds_port > 0 && var.rds_port <= 65535
    error_message = "rds_port must be a valid TCP port."
  }
}

variable "allow_https" {
  description = <<-EOT
    Open port 443 on the ALB.

    Requires an ACM certificate, which requires a registered domain. With no
    domain there is no certificate and no HTTPS listener, so opening 443 would
    advertise a port nothing answers on.
  EOT
  type        = bool
  default     = true
}

variable "allow_http" {
  description = <<-EOT
    Open port 80 on the ALB.

    Two quite different situations want this:

      - WITH a certificate: port 80 exists only to 301-redirect to HTTPS.
        Nothing sensitive crosses it.
      - WITHOUT a certificate: port 80 is the ONLY way in, and traffic is
        unencrypted. That is a real relaxation of the encrypt-in-transit rule
        and is acceptable only for an environment carrying no real data.

    Defaults to false. Enabling it while allow_https is false means plain HTTP
    is the sole ingress path — see the module README.
  EOT
  type        = bool
  default     = false
}

variable "alb_ingress_cidrs" {
  description = <<-EOT
    Source ranges permitted to reach the ALB.

    NO DEFAULT, deliberately. A permissive default is how a load balancer ends
    up open to the internet because nobody typed anything — opening this up has
    to be an explicit, reviewable act.

    For an INTERNAL ALB this is the VPC CIDR: the load balancer resolves to
    private addresses, so any in-VPC client (including a Session Manager tunnel
    through any instance) reaches it directly. A CIDR rather than a security
    group reference is deliberate here — the set of legitimate callers includes
    tunnels through arbitrary instances, which no single group captures.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs cannot be empty; the ALB would be unreachable."
  }

  validation {
    condition     = alltrue([for c in var.alb_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "alb_ingress_cidrs must all be valid IPv4 CIDRs."
  }
}

variable "enable_east_west" {
  description = <<-EOT
    Allow the app tier to egress to the ALB, so applications can call each other.

    Without it the app tier reaches the internet on 443 and nothing inside the
    VPC — a BFF calling RagInference would time out with no obvious cause, since
    egress rules are the least likely place to look.
  EOT
  type        = bool
  default     = true
}

variable "alb_listener_port" {
  description = <<-EOT
    Port the ALB listens on, used for the east-west egress rule.

    80 while there is no certificate; 443 once a domain and ACM certificate
    exist.
  EOT
  type        = number
  default     = 80
}

variable "tags" {
  description = "Additional tags merged onto all resources."
  type        = map(string)
  default     = {}
}
