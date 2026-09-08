# =============================================================================
# S3 model-store module — outputs
# =============================================================================
output "bucket_name" {
  description = "Name of the model-store bucket."
  value       = aws_s3_bucket.models.id
}

output "bucket_arn" {
  description = "ARN of the model-store bucket (used to scope the Pod Identity IAM policy)."
  value       = aws_s3_bucket.models.arn
}
