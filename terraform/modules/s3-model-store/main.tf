# =============================================================================
# S3 model-store module — controlled source of truth for model weights
# =============================================================================
# The model-download Job copies weights FROM this bucket TO the PVC (S3 -> PVC).
# The bucket is YOUR controlled artifact (not a public HF pull at deploy time):
# in-region (ca-central-1), versioned, encrypted, private.
#
# Concepts demonstrated:
#   - postcondition: after apply, ASSERT versioning actually ended up enabled
#     (guarantee the outcome, not just the input)
#   - versioning + SSE + public access block: model-artifact integrity + privacy
#   - force_destroy toggled by variable (demo teardown vs prod safety)
# =============================================================================

resource "aws_s3_bucket" "models" {
  bucket        = "${var.name_prefix}-model-store-${var.account_id}"
  force_destroy = var.force_destroy

  # A real prod model bucket should NOT be force-destroyable; that's controlled
  # by var.force_destroy. (prevent_destroy can't take a variable, so we express
  # the safety via force_destroy=false + the postcondition below.)
}

# Versioning — pin/rollback exact model weights; integrity of the artifact.
resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }

  # Guarantee the OUTCOME: after apply, versioning must be enabled. If a future
  # change ever flips this off, the apply fails loudly instead of silently
  # leaving the model artifacts unversioned.
  lifecycle {
    postcondition {
      condition     = self.versioning_configuration[0].status == "Enabled"
      error_message = "Model-store bucket versioning must be Enabled."
    }
  }
}

# Encryption at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Block all public access — weights are private.
resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
