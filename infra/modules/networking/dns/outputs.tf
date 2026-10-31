output "namespace_id" {
  description = "Cloud Map namespace id. Pass to a service module so it can register a discovery service."
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "namespace_arn" {
  description = "Namespace ARN."
  value       = aws_service_discovery_private_dns_namespace.this.arn
}

output "namespace_name" {
  description = "Namespace DNS suffix (e.g. genai-dev.internal). A service resolves at <service>.<this>."
  value       = aws_service_discovery_private_dns_namespace.this.name
}

output "hosted_zone_id" {
  description = "Route53 private hosted zone id backing the namespace."
  value       = aws_service_discovery_private_dns_namespace.this.hosted_zone
}
