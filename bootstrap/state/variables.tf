################################################################################
# GitHub
################################################################################

variable "github_repository" {
  description = "GitHub repository (owner/name) whose Actions may deploy to this account. Set in terragrunt.hcl."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "Use the owner/name form, for example basenote-dev/gitea-deployment."
  }
}

variable "use_existing_github_oidc_provider" {
  description = "Trust the account's existing GitHub OIDC provider instead of creating one (terragrunt.hcl reads USE_EXISTING_GITHUB_OIDC_PROVIDER). For accounts where another project already made it."
  type        = bool
  default     = false
}

variable "manage_github" {
  description = "Create the GitHub side (environments, AWS_ROLE_ARN variables, BOOTSTRAPPED) and look up the repo's IDs. Needs GITHUB_TOKEN with admin on the repo. Off for a laptop-only deploy with no pipeline."
  type        = bool
  default     = true
}

################################################################################
# State Key
################################################################################

variable "existing_state_kms_key_id" {
  description = "ID of a state KMS key kept from an earlier build of this account, to adopt it and its alias once (terragrunt.hcl reads EXISTING_STATE_KMS_KEY_ID). The key outlives teardowns because KMS keys can't be deleted at once. Null creates a new key."
  type        = string
  default     = null
}
