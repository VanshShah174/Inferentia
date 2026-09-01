# =============================================================================
# EKS module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix (e.g. 'inferentia')."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control-plane Kubernetes version."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the cluster + node group."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (for public API access / public LBs)."
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
}

variable "node_min" {
  description = "Min nodes."
  type        = number
}

variable "node_max" {
  description = "Max nodes."
  type        = number
}

variable "node_desired" {
  description = "Desired nodes."
  type        = number
}

variable "pod_identity_agent_version" {
  description = "Version of the eks-pod-identity-agent addon. Null = let the data source pick the default compatible version for the cluster K8s version."
  type        = string
  default     = null
}
