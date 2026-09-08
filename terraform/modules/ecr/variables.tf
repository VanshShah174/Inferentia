# =============================================================================
# ECR module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix (e.g. 'inferentia')."
  type        = string
}

variable "repository_names" {
  description = "ECR repository names to create (e.g. ['vllm-cpu'])."
  type        = list(string)
  default     = ["vllm-cpu"]
}

variable "image_tag_mutability" {
  description = "IMMUTABLE (recommended: a tag can't be overwritten -> supports build-once/sign-once) or MUTABLE."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }
}

variable "untagged_expiry_days" {
  description = "Expire untagged images after this many days (housekeeping)."
  type        = number
  default     = 14
}
