# Private service-discovery namespace for internal (east-west) traffic.
#
# A Cloud Map private DNS namespace — which creates a Route53 private hosted zone
# scoped to the VPC. Backend Fargate services (RagInference, later Qdrant)
# register a Cloud Map service in it and become reachable at
# <service>.<namespace>:<port> from any in-VPC client, with NO load balancer and
# no public exposure. Chosen over an internal ALB for pure backend services: it
# needs no listener, carries no hourly charge, and is unaffected by the ingress
# toggle (which governs user-facing reach, not east-west service calls).

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.namespace_name
  vpc         = var.vpc_id
  description = "Private service-discovery namespace for ${var.name_prefix} internal services."

  tags = merge(var.tags, {
    Name = var.namespace_name
  })
}
