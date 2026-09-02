# =============================================================================
# Locals — computed names + the common tag set
# =============================================================================
# name_prefix centralizes naming so every resource is consistently named.
# common_tags is applied via provider default_tags (see providers.tf), so we
# don't repeat tags on every resource.
# =============================================================================
locals {
  name_prefix = var.project # e.g. "inferentia"

  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "platform"
    Region    = var.region
  }
}
