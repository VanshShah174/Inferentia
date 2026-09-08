# =============================================================================
# S3 model-store module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix (e.g. 'inferentia')."
  type        = string
}

variable "account_id" {
  description = "AWS account id, used to make the bucket name globally unique."
  type        = string
}

variable "force_destroy" {
  description = "Allow the bucket to be emptied+destroyed on `terraform destroy`. TRUE for demo/portfolio teardown; FALSE for a real prod bucket."
  type        = bool
  default     = false
}
