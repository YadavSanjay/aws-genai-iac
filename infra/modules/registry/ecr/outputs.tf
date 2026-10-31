output "repository_urls" {
  description = "Map of repository name -> URL. This is what `docker push` targets."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repository name -> ARN. Use to scope pull permissions on task/instance roles."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}

output "registry_id" {
  description = "Registry (account) id hosting these repositories."
  value       = values(aws_ecr_repository.this)[0].registry_id
}
