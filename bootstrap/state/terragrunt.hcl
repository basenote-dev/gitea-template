# One-time bootstrap of the account your AWS credentials point at: state bucket and KMS key, CI
# roles, app secrets and, with GITHUB_TOKEN, the GitHub environments (see README.md). A person
# runs it from a laptop; CI never does. Two ways:
#
#   Laptop only (no GitHub): this unit runs first inside the whole run, from bootstrap/
#     terragrunt run --all apply --backend-bootstrap
#
#   With CI: this unit once from a laptop (from bootstrap/), then GitHub Actions deploys
#     GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
#
# root.hcl generates the AWS provider and the S3 backend, but no state encryption: this unit
# creates the key that encryption uses.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# Copy the whole repo into the Terragrunt cache so ../../modules resolves from there.
terraform {
  source = "${get_repo_root()}//${get_path_from_repo_root()}"
}

# `run --all` never destroys this unit, which holds the state bucket and key. CI skips it
# entirely, because the CI roles should not be able to change their own trust. A direct
# `terragrunt apply` here is not affected.
exclude {
  if      = true
  actions = get_env("GITHUB_ACTIONS", "") == "true" ? ["all"] : ["destroy"]
}

inputs = {
  # owner/name of this clone's origin remote (root.hcl), so a fork trusts its own repository.
  github_repository = include.root.locals.repo

  # Without GITHUB_TOKEN (laptop-only deploy) the bootstrap skips every GitHub resource.
  manage_github = get_env("GITHUB_TOKEN", "") != ""

  # Set EXISTING_STATE_KMS_KEY_ID once to adopt a state key kept from an earlier build of this
  # account (the key and its alias are then in state). Unset, a new key is created.
  existing_state_kms_key_id = get_env("EXISTING_STATE_KMS_KEY_ID", "") == "" ? null : get_env("EXISTING_STATE_KMS_KEY_ID")

  # Set USE_EXISTING_GITHUB_OIDC_PROVIDER=true when the account already has a GitHub OIDC
  # provider from another project. AWS allows only one.
  use_existing_github_oidc_provider = get_env("USE_EXISTING_GITHUB_OIDC_PROVIDER", "false") == "true"
}
