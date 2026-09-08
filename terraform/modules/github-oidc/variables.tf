# =============================================================================
# github-oidc module — inputs
# =============================================================================
variable "name_prefix" {
  description = "Naming prefix (e.g. 'inferentia')."
  type        = string
}

variable "github_org" {
  description = "GitHub org/owner (e.g. 'VanshShah174')."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (e.g. 'Inferentia')."
  type        = string
}

variable "github_org_id" {
  description = <<-EOT
    Numeric GitHub organization/owner ID. Since 2026-07-15 GitHub issues OIDC
    'sub' claims for NEW repositories in an immutable-ID format that embeds the
    org id and repo id: repo:<org>@<orgid>/<repo>@<repoid>:.... A trust policy
    matching only the classic repo:<org>/<repo>:... pattern fails for such
    repos with 'Not authorized to perform sts:AssumeRoleWithWebIdentity'. When
    set (non-null), the trust policies ALSO accept the immutable-ID subjects so
    the module works regardless of when the repo was created. Leave null to
    match only the classic format (fine for repos created before 2026-07-15).
    Find it: `gh api users/<org> --jq .id` (or orgs/<org>).
  EOT
  type        = string
  default     = null
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID (pairs with github_org_id for the immutable-ID sub format). Find it: `gh api repos/<org>/<repo> --jq .id`. Only used when github_org_id is set."
  type        = string
  default     = null
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository CI pushes to (least-privilege scope for the push role)."
  type        = string
}

variable "build_branches" {
  description = "Branches whose PRs/pushes may assume the build+push role (build-and-scan runs on PRs to qa+ppd; sign runs on PRs to ppd). Used to scope branch-ref subjects."
  type        = list(string)
  default     = ["qa", "ppd"]
}

variable "prod_branch" {
  description = "Branch that may assume the read-only verify role (promotion-gate runs on PRs to main)."
  type        = string
  default     = "main"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one provider per issuer URL is allowed per account)."
  type        = bool
  default     = true
}
