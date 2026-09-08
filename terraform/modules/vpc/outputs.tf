# =============================================================================
# VPC module — outputs (consumed by the eks/pod-identity modules)
# =============================================================================
output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (where EKS nodes run)."
  value       = [for s in aws_subnet.private : s.id]
}
