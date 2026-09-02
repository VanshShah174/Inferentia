# =============================================================================
# Remote state backend — S3 with NATIVE locking (no DynamoDB)
# =============================================================================
# State lives in the bucket created by terraform/bootstrap.
#
# use_lockfile = true  -> S3-native state locking (Terraform >= 1.10 GA in 1.11).
#   DynamoDB-based locking is DEPRECATED, so we do NOT provision a lock table.
#   S3 alone handles both storage and locking via a lock object.
# encrypt = true       -> state encrypted at rest.
#
# NOTE: backend config cannot use variables/interpolation. The bucket name
# contains the account id (from bootstrap output). Provide it at init time:
#   terraform init \
#     -backend-config="bucket=inferentia-tfstate-<ACCOUNT_ID>"
# (or add a backend.hcl and `terraform init -backend-config=backend.hcl`).
# =============================================================================
terraform {
  backend "s3" {
    # bucket is supplied at init via -backend-config (contains account id)
    key          = "inferentia/platform/terraform.tfstate"
    region       = "ca-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
