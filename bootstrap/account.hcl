# Which AWS account and region everything deploys to, and the cost-allocation tags every
# resource gets. Read by root.hcl (provider, backend, encryption) and by every unit here.
#
# Nothing here names a specific AWS account: whoever runs Terragrunt deploys into the account of
# their own credentials (set EXPECTED_ACCOUNT_ID to make OpenTofu refuse any other account).
locals {
  account_name = "sandbox"
  account_id   = get_aws_account_id()
  aws_region   = get_env("AWS_REGION", "us-west-2")

  # Who pays, which business unit and team own it, which project, which environment. Activate
  # them as cost allocation tags in Billing (management account of the AWS Organization).
  tags = {
    "melange-industries:cost-center"   = "dev"
    "melange-industries:business-unit" = "engineering"
    "melange-industries:team"          = "platform"
    "melange-industries:project"       = "gitea"
    "melange-industries:environment"   = "sandbox"
  }
}
