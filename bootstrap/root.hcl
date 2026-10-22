# Shared Terragrunt configuration, included by every unit in this folder:
#
#   state/   one-time setup: state bucket, state KMS key, CI roles, secrets (OpenTofu in state/)
#   gitea/   the Gitea stack (OpenTofu in aws/, then Helmfile from its hooks)
#
# It reads account.hcl and generates each unit's backend and AWS provider, so no unit repeats
# them. State encryption is generated in gitea/terragrunt.hcl, which finds the key through
# state/'s outputs.

locals {
  project = "gitea"
  # owner/name of the clone's origin remote (https or ssh URL), so a fork trusts itself.
  # "unknown" when the checkout has no origin.
  repo = try(
    trimsuffix(regex("[^/:]+/[^/:]+$", trimspace(run_cmd("--terragrunt-quiet", "git", "remote", "get-url", "origin"))), ".git"),
    "unknown",
  )

  # Opt-in account guard: with EXPECTED_ACCOUNT_ID set, OpenTofu refuses credentials for any
  # other account. Unset, the account is whatever the caller's credentials point at.
  expected_account_id = get_env("EXPECTED_ACCOUNT_ID", "")

  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
}

# The gitea unit's state encryption is OpenTofu-only, so never fall back to Terraform.
terraform_binary = "tofu"

################################################################################
# Remote State
################################################################################
# One S3 bucket per account. `terragrunt --backend-bootstrap` creates it (s3_bucket_tags are used
# then) and state/ adopts it afterwards with the s3-bucket module. The key is the unit's name
# (state/ or gitea/tofu.tfstate). S3 native lockfiles, no DynamoDB table.
#
# The bucket settings Terragrunt applies on --backend-bootstrap match what the s3-bucket module
# manages (AES256), and Terragrunt leaves the bucket policy alone: the module owns it (TLS-only),
# so the two never overwrite each other.

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket       = "${local.project}-tfstate-${local.account.account_id}-${local.account.aws_region}"
    key          = "${path_relative_to_include()}/tofu.tfstate"
    region       = local.account.aws_region
    encrypt      = true
    use_lockfile = true

    bucket_sse_algorithm     = "AES256"
    skip_bucket_root_access  = true
    skip_bucket_enforced_tls = true
  }
}

################################################################################
# AWS Provider
################################################################################
# Region and account come from account.hcl (the caller's own credentials). With
# EXPECTED_ACCOUNT_ID set, allowed_account_ids makes OpenTofu refuse credentials for any other
# account.

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.account.aws_region}"
      allowed_account_ids = ${local.expected_account_id == "" ? "null" : jsonencode([local.expected_account_id])}
    }
  EOF
}
