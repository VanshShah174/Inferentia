# =============================================================================
# Bootstrap — Terraform state backend (ONE-TIME, local state)
# =============================================================================
# Chicken-and-egg fix: the platform tier stores its state in S3, but something
# has to create that S3 bucket first. This tiny config creates the state bucket
# using LOCAL state, is applied ONCE, and then never touched again.
#
# Usage (once, manually):
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
# After this, environments/platform/backend.tf points at this bucket.
#
# The bucket name is globally unique via the account id, so it works in any
# account without collisions.
# =============================================================================

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  # NOTE: no backend block here on purpose — bootstrap uses LOCAL state.
  # (You cannot store the state-bucket's own state in the bucket it creates.)
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for the state bucket. Canada Central for data residency."
  type        = string
  default     = "ca-central-1"
}

variable "project" {
  description = "Project name, used in resource naming."
  type        = string
  default     = "inferentia"
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Tier      = "bootstrap"
    Purpose   = "terraform-remote-state"
  }
}

# -----------------------------------------------------------------------------
# The state bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name
  tags   = local.tags

  # This bucket holds ALL Terraform state. Losing it = losing the ability to
  # manage every resource. Never allow an accidental destroy.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning — so a corrupted/overwritten state can be rolled back.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption at rest (SSE) — state can contain sensitive values.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Block ALL public access — state must never be internet-reachable.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Outputs — used to configure environments/platform/backend.tf
# -----------------------------------------------------------------------------
output "state_bucket_name" {
  description = "Name of the S3 bucket that stores Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "region" {
  description = "Region the state bucket lives in."
  value       = var.region
}
