# =============================================================================
# pod-identity module — outputs
# =============================================================================
output "role_arn" {
  description = "ARN of the model-loader IAM role (for reference/debugging)."
  value       = aws_iam_role.model_loader.arn
}

output "role_name" {
  description = "Name of the model-loader IAM role."
  value       = aws_iam_role.model_loader.name
}

output "associations" {
  description = "Map of namespace -> Pod Identity association id."
  value       = { for ns, assoc in aws_eks_pod_identity_association.model_loader : ns => assoc.association_id }
}
