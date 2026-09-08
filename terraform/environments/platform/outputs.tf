# =============================================================================
# Platform outputs
# =============================================================================
# Surfaced for humans (kubectl/helm wiring) and potentially for other configs
# via terraform_remote_state. Extended as each module is wired in.
# =============================================================================

output "vpc_id" {
  description = "ID of the platform VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (where EKS nodes run)."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs (load balancers / NAT)."
  value       = module.vpc.public_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  description = "Map of ECR repo name -> URL (for docker push / helm image ref)."
  value       = module.ecr.repository_urls
}

output "model_bucket_name" {
  description = "Name of the S3 model-store bucket (set as model.s3Bucket in Helm values)."
  value       = module.model_store.bucket_name
}

output "model_loader_role_arn" {
  description = "IAM role ARN mapped to the model-loader ServiceAccount via Pod Identity."
  value       = module.pod_identity.role_arn
}

output "ci_push_role_arn" {
  description = "OIDC role ARN for CI build+push. Set as GitHub repo variable AWS_CI_PUSH_ROLE_ARN."
  value       = module.github_oidc.push_role_arn
}

output "ci_verify_role_arn" {
  description = "OIDC role ARN for CI verify (promotion-gate). Set as GitHub repo variable AWS_CI_VERIFY_ROLE_ARN."
  value       = module.github_oidc.verify_role_arn
}
