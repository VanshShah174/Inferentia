# =============================================================================
# Terraform & provider version constraints
# =============================================================================
# Pinning both the CLI and providers = reproducible plans. required_version
# is >= 1.11 specifically because we rely on S3-native state locking
# (use_lockfile) and ephemeral/write-only argument support (GA in 1.11).
# =============================================================================
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # kubernetes/helm providers are added when we wire cluster-facing resources.
  }
}
