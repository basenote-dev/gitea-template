# Shared Terragrunt configuration, included by every unit in this folder:
#
#   state/   one-time setup: state bucket, state KMS key, CI roles, secrets (OpenTofu in state/)
#   gitea/   the Gitea stack (OpenTofu in aws/, then Helmfile from its hooks)
#
# It reads account.hcl and generates each unit's backend, AWS provider and OpenTofu state
# encryption, so no unit repeats them.

locals {
  project = "gitea"
  # owner/name of the clone's origin remote (https or ssh URL), so a fork tags and trusts itself.
  # "unknown" when the checkout has no origin.
  repo = try(
    trimsuffix(regex("[^/:]+/[^/:]+$", trimspace(run_cmd("--terragrunt-quiet", "git", "remote", "get-url", "origin"))), ".git"),
    "unknown",
  )

  # Opt-in account guard: with EXPECTED_ACCOUNT_ID set, OpenTofu refuses credentials for any
  # other account. Unset, the account is whatever the caller's credentials point at.
  expected_account_id = get_env("EXPECTED_ACCOUNT_ID", "")

  # state/ creates the encryption key, so it is the one unit without state encryption.
  is_state_unit = path_relative_to_include() == "state"
  account       = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals

  # Cost-allocation tags from account.hcl, plus where the resource is managed from.
  default_tags = merge(local.account.tags, {
    "melange-industries:managed-by" = "terragrunt"
    "melange-industries:repo"       = local.repo
  })
}

# The encryption block below is OpenTofu-only, so never fall back to Terraform.
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

    s3_bucket_tags           = local.account.tags
    bucket_sse_algorithm     = "AES256"
    skip_bucket_root_access  = true
    skip_bucket_enforced_tls = true
  }
}

################################################################################
# AWS Provider
################################################################################
# Region and account come from account.hcl (the caller's own credentials). With
# EXPECTED_ACCOUNT_ID set, allowed_account_ids makes OpenTofu refuse to run with credentials for
# any other account (config for one account can never touch another by accident). Every resource gets
# the account's cost-allocation tags through default_tags.

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.account.aws_region}"
      allowed_account_ids = ${local.expected_account_id == "" ? "null" : jsonencode([local.expected_account_id])}

      default_tags {
        tags = ${jsonencode(local.default_tags)}
      }
    }
  EOF
}

################################################################################
# State and Plan Encryption
################################################################################
# OpenTofu client-side encryption (AES-GCM, data key from the account's KMS key
# alias/gitea-tofu-state). `enforced` makes OpenTofu refuse to read or write unencrypted state
# or plan files, so anything a provider keeps in state (and plan files CI saves) is ciphertext
# even to someone who can read the bucket.
#
# Disabled for state/: it creates that key, so it can't depend on it.

generate "encryption" {
  path      = "encryption.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.is_state_unit
  contents  = <<-EOF
    terraform {
      encryption {
        key_provider "aws_kms" "state" {
          kms_key_id = "alias/${local.project}-tofu-state"
          region     = "${local.account.aws_region}"
          key_spec   = "AES_256"
        }

        method "aes_gcm" "state" {
          keys = key_provider.aws_kms.state
        }

        state {
          method   = method.aes_gcm.state
          enforced = true
        }

        plan {
          method   = method.aes_gcm.state
          enforced = true
        }
      }
    }
  EOF
}
