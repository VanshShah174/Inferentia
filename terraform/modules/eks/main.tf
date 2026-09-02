# =============================================================================
# EKS module — the ONE cluster + managed node group + Pod Identity Agent
# =============================================================================
# Concepts demonstrated:
#   - precondition: assert >= 2 private subnets BEFORE the cluster is created
#     (fail fast with a clear message rather than an opaque AWS error)
#   - IAM roles for the control plane and the node group (least-privilege
#     managed policies)
#   - EKS Pod Identity Agent ADDON — the enabler for Pod Identity (chosen over
#     IRSA): no OIDC provider, associations configured via the EKS API
# =============================================================================

# -----------------------------------------------------------------------------
# IAM — EKS control plane role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# EKS cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.name_prefix}-eks"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    # Nodes live in private subnets; include public subnets so the API/LBs
    # can be reached during bootstrap.
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Fail fast if the network foundation is wrong.
  lifecycle {
    precondition {
      condition     = length(var.private_subnet_ids) >= 2
      error_message = "EKS requires at least 2 private subnets across AZs for HA."
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# -----------------------------------------------------------------------------
# IAM — node group role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name_prefix}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# The three managed policies every EKS node needs. for_each over a set keeps it
# tidy and avoids three near-identical attachment blocks.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# Managed node group (nodes in PRIVATE subnets)
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name_prefix}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    min_size     = var.node_min
    max_size     = var.node_max
    desired_size = var.node_desired
  }

  # Zero-downtime node replacement on config changes.
  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# -----------------------------------------------------------------------------
# VPC CNI addon — MANAGED so we can enable NetworkPolicy enforcement
# -----------------------------------------------------------------------------
# The VPC CNI ships pre-installed on EKS, but UNMANAGED it enforces no
# NetworkPolicy — meaning the chart's default-deny/allow policies would be
# accepted by the API server yet silently ignored (any pod could still reach
# vLLM:8000). Bringing the addon under Terraform lets us flip on the built-in
# network-policy agent via configuration_values, so the policies are actually
# enforced (disallowed packets dropped at the node). This is the CNI-side half
# of the NetworkPolicy story; the chart is the K8s-object half.
#
# We deliberately do NOT set service_account_role_arn here: the node group's
# instance role already carries AmazonEKS_CNI_Policy, so the addon keeps
# working with node-role creds (no Pod Identity needed for the CNI itself).
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = coalesce(var.vpc_cni_version, data.aws_eks_addon_version.vpc_cni.version)

  # AWS-documented key to turn on the network-policy agent. jsonencode keeps
  # the payload valid regardless of the bool. When false, policies remain
  # inert (accepted but unenforced) — the toggle mirrors values networkPolicy.
  configuration_values = jsonencode({
    enableNetworkPolicy = var.enable_network_policy ? "true" : "false"
  })

  # PRESERVE: don't clobber any in-cluster CNI config the addon adopts when it
  # takes over the pre-installed self-managed CNI.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.this]
}

# -----------------------------------------------------------------------------
# EKS Pod Identity Agent addon — enables Pod Identity (NOT IRSA)
# -----------------------------------------------------------------------------
# This DaemonSet is what lets pods receive IAM creds via Pod Identity
# associations (created in the pod-identity module). No OIDC provider needed.
#
# Resolve the default compatible addon version for this cluster's K8s version
# when the caller doesn't pin one (coalesce: use the pinned value if given,
# else the data-source default).
data "aws_eks_addon_version" "pod_identity" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = coalesce(var.pod_identity_agent_version, data.aws_eks_addon_version.pod_identity.version)

  depends_on = [aws_eks_node_group.this]
}

# -----------------------------------------------------------------------------
# EBS CSI driver addon — REQUIRED for dynamic EBS gp3 PVC provisioning
# -----------------------------------------------------------------------------
# WITHOUT this, PVCs (the model-weights volume) stay Pending forever because
# nothing provisions the underlying EBS volume. EKS has no default dynamic
# provisioner (unlike kind's local-path), so this addon is mandatory for our
# S3 -> PVC model flow. The driver runs with its own IAM role, granted via
# Pod Identity (consistent with the rest of the platform — no IRSA/OIDC).

# IAM role for the EBS CSI driver, trusted by the Pod Identity principal.
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_node_group.this]
}
