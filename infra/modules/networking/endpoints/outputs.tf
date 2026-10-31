output "s3_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "s3_prefix_list_id" {
  description = <<-EOT
    Prefix list of S3's IP ranges for this region.

    Use it as a security-group egress destination instead of 0.0.0.0/0 when a
    workload only needs S3 — the ranges then track AWS's changes automatically.
  EOT
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "s3_endpoint_policy" {
  description = "The effective endpoint policy JSON, or null when left at AWS's default."
  value       = try(data.aws_iam_policy_document.s3[0].json, null)
}
