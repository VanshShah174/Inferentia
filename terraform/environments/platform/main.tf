# =============================================================================
# Platform composition (root module)
# =============================================================================
# THIN by design: it only calls child modules and wires their outputs together.
# All real logic lives in ../../modules/*. This is the "define once (modules),
# vary by inputs (here)" pattern.
#
# This composition wires FIVE modules (all present and wired):
#   [x] vpc            (network foundation: VPC, subnets, NAT, routes)
#   [x] eks            (the one cluster + node group + Pod Identity & EBS CSI addons)
#   [x] ecr            (image registry, immutable tags, scan-on-push)
#   [x] s3-model-store (model weights bucket)
#   [x] pod-identity   (least-privilege S3 access, no static keys)
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Network foundation
# -----------------------------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# -----------------------------------------------------------------------------
# EKS — the ONE cluster (shared across all environments via namespaces)
# -----------------------------------------------------------------------------
module "eks" {
  source = "../../modules/eks"

  name_prefix        = local.name_prefix
  kubernetes_version = var.kubernetes_version
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids
  node_instance_type = var.node_instance_type
  node_min           = var.node_min
  node_max           = var.node_max
  node_desired       = var.node_desired
}

# -----------------------------------------------------------------------------
# ECR — private registry for the vLLM image (unblocks CI push + Cosign signing)
# -----------------------------------------------------------------------------
module "ecr" {
  source = "../../modules/ecr"

  name_prefix      = local.name_prefix
  repository_names = ["vllm-cpu"]
}

# -----------------------------------------------------------------------------
# S3 model store — controlled source of truth for model weights (S3 -> PVC)
# -----------------------------------------------------------------------------
module "model_store" {
  source = "../../modules/s3-model-store"

  name_prefix   = local.name_prefix
  account_id    = data.aws_caller_identity.current.account_id
  force_destroy = var.model_bucket_force_destroy
}

# -----------------------------------------------------------------------------
# Pod Identity — least-privilege S3 read for the model-loader SA (no static keys)
# -----------------------------------------------------------------------------
module "pod_identity" {
  source = "../../modules/pod-identity"

  name_prefix      = local.name_prefix
  cluster_name     = module.eks.cluster_name
  model_bucket_arn = module.model_store.bucket_arn
  namespaces       = var.inference_namespaces
  service_account  = var.model_service_account
}

# -----------------------------------------------------------------------------
# GitHub OIDC — keyless CI -> ECR (no static AWS keys in GitHub Secrets)
# -----------------------------------------------------------------------------
# Mints short-lived, per-run credentials for the CI workflows via OIDC. Trust
# is anchored to THIS repo (+ branches/events), so the pipeline is team-usable
# with nothing to rotate. Push role scoped to the vllm-cpu ECR repo ARN.
module "github_oidc" {
  source = "../../modules/github-oidc"

  name_prefix        = local.name_prefix
  github_org         = var.github_org
  github_repo        = var.github_repo
  github_org_id      = var.github_org_id
  github_repo_id     = var.github_repo_id
  ecr_repository_arn = module.ecr.repository_arns["vllm-cpu"]
}

# -----------------------------------------------------------------------------
# Kyverno ECR read — Pod Identity for image-signature verification
# -----------------------------------------------------------------------------
# The verify-image-signatures ClusterPolicy (Enforce in ppd/prod) must pull the
# image manifest from ECR to check its Cosign signature. Kyverno's admission
# controller SA has no AWS creds by default, so verification fails with
# "401 Unauthorized" fetching the manifest — blocking even correctly-signed
# images. This grants the admission controller READ-ONLY ECR access via EKS Pod
# Identity (same zero-static-keys pattern as the model-loader): trust the
# pods.eks.amazonaws.com principal, associate (cluster, kyverno ns, admission
# controller SA) -> this role. No imagePullSecret, no static keys.
data "aws_iam_policy_document" "kyverno_ecr_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kyverno_ecr_read" {
  name               = "${local.name_prefix}-kyverno-ecr-read"
  assume_role_policy = data.aws_iam_policy_document.kyverno_ecr_trust.json
}

data "aws_iam_policy_document" "kyverno_ecr_read" {
  # GetAuthorizationToken is account-wide (no resource ARN).
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  # Read the image manifest + layers to verify the signature. Scoped to the
  # one vllm-cpu repo.
  statement {
    sid    = "EcrRead"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [module.ecr.repository_arns["vllm-cpu"]]
  }
}

resource "aws_iam_role_policy" "kyverno_ecr_read" {
  name   = "${local.name_prefix}-kyverno-ecr-read"
  role   = aws_iam_role.kyverno_ecr_read.id
  policy = data.aws_iam_policy_document.kyverno_ecr_read.json
}

resource "aws_eks_pod_identity_association" "kyverno_ecr_read" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kyverno"
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno_ecr_read.arn
}
