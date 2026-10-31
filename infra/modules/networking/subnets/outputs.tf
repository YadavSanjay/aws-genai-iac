output "availability_zones" {
  description = "AZs the subnets were spread across."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet ids, in AZ order."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet ids, in AZ order."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_subnet_ids_by_az" {
  description = "Map of AZ -> public subnet id. Use when AZ affinity matters (e.g. placing a NAT instance)."
  value       = { for az, subnet in aws_subnet.public : az => subnet.id }
}

output "private_subnet_ids_by_az" {
  description = "Map of AZ -> private subnet id."
  value       = { for az, subnet in aws_subnet.private : az => subnet.id }
}

output "public_route_table_id" {
  description = "Shared public route table id."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = <<-EOT
    Private route table ids, in AZ order. Needed by the S3 gateway endpoint and
    by whatever egress device is added later.
  EOT
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "private_route_table_ids_by_az" {
  description = "Map of AZ -> private route table id."
  value       = { for az, table in aws_route_table.private : az => table.id }
}

output "all_route_table_ids" {
  description = "Public and private route table ids together — convenient for gateway endpoint association."
  value       = concat([aws_route_table.public.id], [for az in local.azs : aws_route_table.private[az].id])
}
