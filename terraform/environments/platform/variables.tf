# =============================================================================
# Input variables — typed, defaulted, and validated
# =============================================================================
# validation blocks catch bad inputs at PLAN time (fail fast, clear message)
# rather than surfacing as a confusing AWS API error mid-apply.
# =============================================================================

variable "project" {
  description = "Project name; used as the naming/tagging prefix."
  type        = string
  default     = "inferentia"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen, 2-21 chars."
  }
}

variable "region" {
  description = "AWS region. ca-central-1 (Canada Central) for data residency."
  type        = string
  default     = "ca-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the platform VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }
}

variable "az_count" {
  description = "How many AZs to spread subnets across (EKS needs >= 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (EKS requires at least 2 AZs)."
  }
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version."
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "t3.large"
}

variable "node_min" {
  description = "Minimum nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_max" {
  description = "Maximum nodes in the managed node group."
  type        = number
  default     = 3
}

variable "node_desired" {
  description = "Desired nodes in the managed node group."
  type        = number
  default     = 2
}

variable "model_bucket_force_destroy" {
  description = "Allow the model-store bucket to be emptied+destroyed. TRUE only for non-prod/demo teardown; keep FALSE for a real prod bucket."
  type        = bool
  default     = true
}

variable "inference_namespaces" {
  description = "Kubernetes namespaces (one per environment) that the model-download ServiceAccount will run in. Used for Pod Identity associations."
  type        = list(string)
  default     = ["inference-dev", "inference-qa", "inference-ppd", "inference-prod"]
}

variable "model_service_account" {
  description = "Name of the ServiceAccount the model-download pod uses (Pod Identity target)."
  type        = string
  default     = "vllm-model-loader"
}
