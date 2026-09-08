# =============================================================================
# ECR module — private image registry for the vLLM image(s)
# =============================================================================
# Unblocks the CI supply chain: build-and-scan pushes here, sign-and-publish
# Cosign-signs the pushed image, promotion-gate verifies the signature.
#
# Security choices:
#   - IMMUTABLE tags: a tag can't be overwritten, so "build once, sign once,
#     promote unchanged" is enforced at the registry level.
#   - scan_on_push: ECR runs a CVE scan on every push (defense in depth with
#     the Trivy scan in CI).
#   - lifecycle policy: expire untagged images to control cost/clutter.
#
# for_each over the repo name set = one repo per name, cleanly.
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.name_prefix}/${each.value}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true # demo/portfolio: allow teardown even if images exist

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lifecycle policy — expire untagged images after N days.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      }
    ]
  })
}
