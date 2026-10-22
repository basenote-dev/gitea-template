################################################################################
# Name Suffix
################################################################################

output "name" {
  description = "gitea-<suffix>: the prefix of every name this stack gives AWS (the gitea unit reads it)"
  value       = local.name
}

output "role_names" {
  description = "Names of the roles the gitea unit gives EKS access entries"
  value = {
    github_plan        = module.github_plan_role.name
    github_apply       = module.github_apply_role.name
    platform_eks_admin = module.platform_eks_admin_role.name
  }
}

################################################################################
# State Bucket
################################################################################

output "state_bucket" {
  description = "S3 bucket holding the OpenTofu state of both units"
  value       = module.state_bucket.s3_bucket_id
}

output "state_kms_key_arn" {
  description = "KMS key OpenTofu uses to encrypt the gitea unit's state and plan files (the gitea unit reads it)"
  value       = aws_kms_key.state.arn
}

output "state_kms_key_alias" {
  description = "Alias of the state encryption key"
  value       = aws_kms_alias.state.name
}

################################################################################
# GitHub OIDC
################################################################################

output "github_oidc_provider_arn" {
  description = "IAM OIDC provider for GitHub Actions tokens"
  value       = local.github_oidc_provider_arn
}

output "github_plan_role_arn" {
  description = "Read-only role assumed by the plan environment"
  value       = module.github_plan_role.arn
}

output "github_apply_role_arn" {
  description = "Admin role assumed by the apply environment (main only)"
  value       = module.github_apply_role.arn
}

output "github_environments" {
  description = "GitHub environments created in the repository, with the role each one assumes"
  value = {
    (local.github_plan_environment)  = module.github_plan_role.arn
    (local.github_apply_environment) = module.github_apply_role.arn
  }
}

################################################################################
# Cluster Admin Role
################################################################################

output "platform_eks_admin_role_arn" {
  description = "Role people assume for cluster admin access (granted by the gitea unit)"
  value       = module.platform_eks_admin_role.arn
}

################################################################################
# Application Secrets
################################################################################

output "secret_names" {
  description = "Map of db/valkey/admin/metrics to the Secrets Manager secret name (values are write-only and not in state)"
  value       = { for k, s in module.app_secret : k => s.secret_name }
}

output "secret_arns" {
  description = "Map of db/valkey/admin/metrics to the Secrets Manager secret ARN"
  value       = { for k, s in module.app_secret : k => s.secret_arn }
}
