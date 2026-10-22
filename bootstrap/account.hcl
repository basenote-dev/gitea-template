# Which AWS account and region everything deploys to. Read by root.hcl (provider, backend) and
# by every unit here.
#
# Nothing here names a specific AWS account: whoever runs Terragrunt deploys into the account of
# their own credentials (set EXPECTED_ACCOUNT_ID to make OpenTofu refuse any other account).
locals {
  account_name = "sandbox"
  account_id   = get_aws_account_id()
  aws_region   = get_env("AWS_REGION", "us-west-2")
}
