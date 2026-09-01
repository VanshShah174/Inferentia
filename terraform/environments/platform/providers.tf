# =============================================================================
# Provider configuration
# =============================================================================
# Region comes from a variable (default ca-central-1). default_tags applies a
# consistent tag set to EVERY taggable resource without repeating it per
# resource — a clean DRY win and good for cost allocation / ownership.
# =============================================================================
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}
