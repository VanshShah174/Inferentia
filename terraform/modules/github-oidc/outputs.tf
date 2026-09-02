# =============================================================================
# github-oidc module — outputs
# =============================================================================
output "push_role_arn" {
  description = "IAM role ARN for CI build+push (build-and-scan, sign-and-publish). Set as the GitHub repo variable AWS_CI_PUSH_ROLE_ARN (or pass to configure-aws-credentials role-to-assume)."
  value       = aws_iam_role.push.arn
}

output "verify_role_arn" {
  description = "IAM role ARN for CI verify (promotion-gate). Set as the GitHub repo variable AWS_CI_VERIFY_ROLE_ARN."
  value       = aws_iam_role.verify.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider used by the CI roles."
  value       = local.oidc_provider_arn
}
