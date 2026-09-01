# =============================================================================
# pod-identity module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix (e.g. 'inferentia')."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name to attach Pod Identity associations to."
  type        = string
}

variable "model_bucket_arn" {
  description = "ARN of the S3 model-store bucket. The role is scoped to read ONLY this bucket."
  type        = string
}

variable "namespaces" {
  description = "Kubernetes namespaces (one per environment) that run the model-loader ServiceAccount."
  type        = list(string)
}

variable "service_account" {
  description = "Name of the ServiceAccount the model-download pod uses. With Pod Identity this SA needs NO IRSA role-arn annotation."
  type        = string
}
