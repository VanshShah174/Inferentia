# =============================================================================
# pod-identity module — least-privilege S3 access for the model-loader pod
# =============================================================================
# This is the payoff of choosing EKS Pod Identity over IRSA:
#   - IAM role trusts the "pods.eks.amazonaws.com" principal (universal trust,
#     NO per-cluster OIDC provider, NO trust-policy edits per cluster)
#   - the role grants ONLY s3:GetObject/ListBucket on the ONE model bucket
#     (least privilege — one bucket, read-only)
#   - a Pod Identity ASSOCIATION per environment namespace maps
#     (cluster, namespace, serviceaccount) -> this role via the EKS API
#   - NO static credentials anywhere, NO role-arn annotation on the SA
#
# for_each over the namespaces set creates one association per environment,
# all sharing the same reusable role.
# =============================================================================

# -----------------------------------------------------------------------------
# Trust policy — the Pod Identity principal (NOT an OIDC federation)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  statement {
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "model_loader" {
  name               = "${var.name_prefix}-model-loader"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# -----------------------------------------------------------------------------
# Permission policy — READ-ONLY on the ONE model bucket (least privilege)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "s3_read" {
  # List the bucket (needed to enumerate objects to sync).
  statement {
    sid       = "ListModelBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.model_bucket_arn]
  }
  # Read objects (the actual weights).
  statement {
    sid       = "GetModelObjects"
    actions   = ["s3:GetObject"]
    resources = ["${var.model_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_read" {
  name   = "${var.name_prefix}-model-loader-s3-read"
  role   = aws_iam_role.model_loader.id
  policy = data.aws_iam_policy_document.s3_read.json
}

# -----------------------------------------------------------------------------
# Pod Identity associations — one per environment namespace
# -----------------------------------------------------------------------------
resource "aws_eks_pod_identity_association" "model_loader" {
  for_each = toset(var.namespaces)

  cluster_name    = var.cluster_name
  namespace       = each.value
  service_account = var.service_account
  role_arn        = aws_iam_role.model_loader.arn
}
