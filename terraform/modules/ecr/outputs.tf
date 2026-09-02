# =============================================================================
# ECR module — outputs
# =============================================================================
output "repository_urls" {
  description = "Map of repo name -> repository URL (for docker push / helm image ref)."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of repo name -> repository ARN."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
