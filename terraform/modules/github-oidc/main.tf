# =============================================================================
# github-oidc module — keyless CI -> AWS via GitHub Actions OIDC
# =============================================================================
# Replaces long-lived AWS access keys in GitHub Secrets with short-lived,
# per-run credentials minted through OIDC federation. No secret is stored
# anywhere; trust is anchored to the REPOSITORY (and specific branches/events),
# not to a person. This is what makes the pipeline team-usable and rotation-
# free: a teammate's PR in this repo inherits access from the repo's identity,
# and there is no shared key to leak or rotate.
#
# TWO roles, matching the progressive-security theme:
#   - push  role: build-and-scan (PR->qa/ppd) pushes the UNSIGNED image, and
#                 sign-and-publish (PR->ppd) pushes the Cosign signature layer.
#                 Scoped to ECR push+pull on the ONE repo ARN.
#   - verify role: promotion-gate (PR->main) pulls to cosign-verify. ECR
#                  READ-ONLY. (Signature verification itself hits Sigstore, not
#                  AWS — so this role only needs pull.)
#
# SUBJECT-CLAIM REALITY (why the trust conditions look the way they do):
#   1. pull_request events do NOT carry the base branch in the 'sub' claim —
#      the claim is simply "repo:<org>/<repo>:pull_request". So we CANNOT
#      distinguish "PR to qa" from "PR to ppd" in the trust policy. Branch
#      targeting is enforced by the WORKFLOWS (each workflow's `on.pull_request.
#      branches`) + GitHub branch protection, not by IAM. We document this
#      rather than pretend IAM scopes it.
#   2. Since 2026-07-15 new repos get an immutable-ID 'sub' format
#      (repo:<org>@<orgid>/<repo>@<repoid>:...). When github_org_id/repo_id are
#      provided we accept BOTH formats so the module is future-proof.
# =============================================================================

data "aws_partition" "current" {}

locals {
  oidc_provider_url = "token.actions.githubusercontent.com"

  # Provider ARN — either the one we create, or the account's existing one.
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.oidc_provider_url}"

  # Whether to also emit the 2026 immutable-ID subject variants.
  use_immutable_ids = var.github_org_id != null && var.github_repo_id != null

  # Classic subject prefixes.
  classic_repo = "repo:${var.github_org}/${var.github_repo}"
  # Immutable-ID subject prefix (2026-07-15+ repos). Empty list when unused.
  immutable_repo = local.use_immutable_ids ? "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}" : null

  # --- PUSH role subjects: the pull_request event (both formats) -------------
  # build-and-scan (PR->qa,ppd) and sign-and-publish (PR->ppd) both run on
  # pull_request, so "repo:...:pull_request" is the subject they present.
  push_subjects = compact(concat(
    ["${local.classic_repo}:pull_request"],
    local.use_immutable_ids ? ["${local.immutable_repo}:pull_request"] : [],
    # Also allow branch-ref subjects for the build branches, so a direct push /
    # workflow_dispatch on those branches (not just PRs) can assume the role.
    [for b in var.build_branches : "${local.classic_repo}:ref:refs/heads/${b}"],
    local.use_immutable_ids ? [for b in var.build_branches : "${local.immutable_repo}:ref:refs/heads/${b}"] : [],
  ))

  # --- VERIFY role subjects: PR->main (pull_request) + main branch ref -------
  verify_subjects = compact(concat(
    ["${local.classic_repo}:pull_request"],
    local.use_immutable_ids ? ["${local.immutable_repo}:pull_request"] : [],
    ["${local.classic_repo}:ref:refs/heads/${var.prod_branch}"],
    local.use_immutable_ids ? ["${local.immutable_repo}:ref:refs/heads/${var.prod_branch}"] : [],
  ))
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# OIDC provider for GitHub Actions (one per account per issuer URL)
# -----------------------------------------------------------------------------
# NOTE: modern AWS STS validates the OIDC token signature against the provider's
# published JWKS, so the legacy thumbprint is no longer security-critical; AWS
# ignores it for this issuer. We still pass a value because the argument is
# required. GitHub's well-known root thumbprint is used by convention.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://${local.oidc_provider_url}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# -----------------------------------------------------------------------------
# Trust policy builder — one statement, aud pinned, sub matched via StringLike
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "push_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = local.push_subjects
    }
  }
}

data "aws_iam_policy_document" "verify_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = local.verify_subjects
    }
  }
}

# -----------------------------------------------------------------------------
# PUSH role — ECR push + pull, scoped to the ONE repo ARN (least privilege)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "push" {
  name                 = "${var.name_prefix}-ci-ecr-push"
  assume_role_policy   = data.aws_iam_policy_document.push_assume.json
  max_session_duration = 3600 # 1h — CI jobs are short; no reason to linger
}

# ecr:GetAuthorizationToken is account-wide (no resource ARN); the push/pull
# actions are scoped to the specific repository ARN.
data "aws_iam_policy_document" "push_perms" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages", # sign-and-publish resolves the digest by tag
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "push" {
  name   = "${var.name_prefix}-ci-ecr-push"
  role   = aws_iam_role.push.id
  policy = data.aws_iam_policy_document.push_perms.json
}

# -----------------------------------------------------------------------------
# VERIFY role — ECR pull only (promotion-gate verifies the signed digest)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "verify" {
  name                 = "${var.name_prefix}-ci-ecr-verify"
  assume_role_policy   = data.aws_iam_policy_document.verify_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "verify_perms" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages", # promotion-gate + nightly resolve the digest by tag
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "verify" {
  name   = "${var.name_prefix}-ci-ecr-verify"
  role   = aws_iam_role.verify.id
  policy = data.aws_iam_policy_document.verify_perms.json
}
