################################################################################
# Names From bootstrap/state
################################################################################
# bootstrap/gitea/terragrunt.hcl passes these from the state unit's outputs.

variable "name" {
  description = "gitea-<suffix>, the prefix of every AWS name in this stack (state unit's random suffix)"
  type        = string

  validation {
    condition     = can(regex("^gitea-[0-9a-f]{6}$", var.name))
    error_message = "Expected gitea-<6 hex characters>, the state unit's name output."
  }
}

variable "role_names" {
  description = "Roles created by bootstrap/state that get EKS access entries: github_plan, github_apply, platform_eks_admin"
  type = object({
    github_plan        = string
    github_apply       = string
    platform_eks_admin = string
  })
}
