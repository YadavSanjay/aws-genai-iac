output "instance_id" {
  description = "Ingest runner instance id."
  value       = aws_instance.runner.id
}

output "private_ip" {
  description = "Private IP."
  value       = aws_instance.runner.private_ip
}

output "role_arn" {
  description = "Instance role ARN."
  value       = aws_iam_role.runner.arn
}

output "role_name" {
  description = "Instance role name."
  value       = aws_iam_role.runner.name
}

output "run_hint" {
  description = "How to run the pipeline once connected via SSM."
  value       = "aws ssm start-session --target ${aws_instance.runner.id} ; then: sudo arag-ingest python scripts/bootstrap_db.py --phase data --ticker <TICKER>"
}
