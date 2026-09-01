# =============================================================================
# VPC module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix for all VPC resources (e.g. 'inferentia')."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }
}

variable "availability_zones" {
  description = "List of AZ names to spread subnets across. EKS requires >= 2."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Provide at least 2 availability zones for EKS HA."
  }
}
