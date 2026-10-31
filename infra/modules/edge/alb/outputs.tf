output "enabled" {
  description = "Whether a load balancer exists. False means SSM port forwarding is the only access path."
  value       = var.enabled
}

output "dns_name" {
  description = <<-EOT
    Public DNS name of the load balancer, or null when disabled.

    With no registered domain this AWS-generated hostname is the only address —
    there is no friendly name and no certificate.
  EOT
  value       = try(aws_lb.this[0].dns_name, null)
}

output "zone_id" {
  description = "Hosted zone id of the load balancer, for an alias record once a domain exists."
  value       = try(aws_lb.this[0].zone_id, null)
}

output "arn" {
  description = "Load balancer ARN, or null when disabled."
  value       = try(aws_lb.this[0].arn, null)
}

output "target_group_arns" {
  description = "Map of application name -> target group ARN."
  value       = { for name, tg in aws_lb_target_group.this : name => tg.arn }
}

output "application_urls" {
  description = <<-EOT
    Reachable URL per application, or the SSM port-forwarding command when the
    load balancer is disabled. Intended to be the single place someone looks to
    answer "how do I reach this right now?".
  EOT
  value = var.enabled ? {
    for name, t in var.targets :
    name => length(t.path_patterns) > 0
    ? "http://${try(aws_lb.this[0].dns_name, "")}${replace(t.path_patterns[0], "/*", "")}"
    : "http://${try(aws_lb.this[0].dns_name, "")}"
    } : {
    for name, t in var.targets :
    name => "aws ssm start-session --target ${t.instance_id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"${t.port}\"],\"localPortNumber\":[\"${t.port}\"]}'"
  }
}
