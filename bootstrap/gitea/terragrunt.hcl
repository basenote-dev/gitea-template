# The Gitea stack: the OpenTofu in aws/ plus everything inside the cluster (Helmfile, run from
# the hooks below).
#
# One command from bootstrap/, the same on a laptop and in CI:
#
#   terragrunt run --all plan|apply|destroy
#
# run --all orders the units: state/ (laptop only), then this one. For this unit:
#
#   plan     tofu plan, then `helmfile diff` (skipped until the cluster exists)
#   apply    tofu apply, then `helmfile apply`
#   destroy  `helmfile destroy` first (removes the load balancers), then tofu destroy
#
# root.hcl generates the backend and the AWS provider (region, account guard, cost tags from
# account.hcl). This file generates the state encryption.
#
# Names come from state/: its random suffix makes everything here gitea-<suffix> (cluster, RDS,
# Valkey, EFS, log groups), and its outputs give the KMS key and role names. Terragrunt locals
# can't read dependency outputs, so the hooks below use dependency.state.outputs directly.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals

  kube_context = "gitea-${local.account.account_name}"
  helmfile_dir = "${get_repo_root()}/helmfile"

  # Helmfile reads this stack's outputs itself (helmfile/values/tofu-outputs.yaml.gotmpl).
  helmfile = ["helmfile", "--no-color", "--environment", local.account.account_name, "--kube-context", local.kube_context]

  # Plan and destroy first ask whether the EKS cluster exists yet (a fresh account has nothing to
  # diff or uninstall). Other commands skip the question.
  check_cluster = contains(["plan", "destroy"], get_terraform_command())
}

################################################################################
# State Unit Outputs
################################################################################
# The name suffix, the state KMS key and the role names, all created by state/. Also orders a
# laptop `run --all`: state/ applies first. In CI state/ is excluded from the run, but its
# outputs are still read from its state (the CI roles can read the bucket). The mocks only serve
# `validate` before the bootstrap has run.

dependency "state" {
  config_path = "../state"

  mock_outputs = {
    name              = "gitea-000000"
    state_kms_key_arn = "arn:aws:kms:us-west-2:000000000000:key/00000000-0000-0000-0000-000000000000"
    role_names = {
      github_plan        = "gitea-000000-github-plan"
      github_apply       = "gitea-000000-github-apply"
      platform_eks_admin = "gitea-000000-platform-eks-admin"
    }
  }
  mock_outputs_allowed_terraform_commands = ["validate"]
}

inputs = {
  name       = dependency.state.outputs.name
  role_names = dependency.state.outputs.role_names
}

################################################################################
# State and Plan Encryption
################################################################################
# OpenTofu client-side encryption (AES-GCM, data key from the state KMS key state/ created).
# `enforced` makes OpenTofu refuse to read or write unencrypted state or plan files, so state and
# saved plan files are ciphertext even to someone who can read the bucket. state/ itself has no
# encryption: it creates the key.

generate "encryption" {
  path      = "encryption.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      encryption {
        key_provider "aws_kms" "state" {
          kms_key_id = "${dependency.state.outputs.state_kms_key_arn}"
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

terraform {
  # Terragrunt runs from a cache copy: copy the whole repo (note the //) so ../modules resolves.
  source = "${get_repo_root()}//aws"

  # Plans wait for a running apply's state lock instead of failing.
  extra_arguments "lock_timeout" {
    commands  = get_terraform_commands_that_need_locking()
    arguments = ["-lock-timeout=20m"]
  }

  # Writes the cluster to ~/.kube/config as context gitea-sandbox. In CI the job's own role has
  # an EKS access entry (github-plan view, github-apply admin). On a laptop the caller is any
  # admin in the account, so kubectl assumes the platform-eks-admin role (created by state/,
  # trusted by the account) instead of needing its own access entry.
  after_hook "kubeconfig" {
    commands = ["apply", "plan"]
    execute = concat([
      "aws", "eks", "update-kubeconfig",
      "--name", dependency.state.outputs.name,
      "--region", local.account.aws_region,
      "--alias", local.kube_context,
      ], get_env("GITHUB_ACTIONS", "") == "true" ? [] : [
      "--role-arn", "arn:aws:iam::${local.account.account_id}:role/${dependency.state.outputs.role_names.platform_eks_admin}",
    ])
    # run_cmd results are cached, so the identical cluster checks below run once.
    if = get_terraform_command() == "apply" || anytrue([
      for cmd in local.check_cluster ? ["check"] : [] :
      trimspace(run_cmd("--terragrunt-quiet", "aws", "eks", "list-clusters",
        "--region", local.account.aws_region,
        "--query", "contains(clusters, '${dependency.state.outputs.name}')",
      "--output", "text")) == "True"
    ])
  }

  # What Helm would change, shown in the plan output (and the PR comment in CI).
  after_hook "helmfile_diff" {
    commands    = ["plan"]
    execute     = concat(local.helmfile, ["diff", "--context", "5", "--suppress-secrets", "--skip-diff-on-install"])
    working_dir = local.helmfile_dir
    if = anytrue([
      for cmd in local.check_cluster ? ["check"] : [] :
      trimspace(run_cmd("--terragrunt-quiet", "aws", "eks", "list-clusters",
        "--region", local.account.aws_region,
        "--query", "contains(clusters, '${dependency.state.outputs.name}')",
      "--output", "text")) == "True"
    ])
  }

  after_hook "helmfile_apply" {
    commands    = ["apply"]
    execute     = concat(local.helmfile, ["apply", "--suppress-secrets", "--skip-diff-on-install"])
    working_dir = local.helmfile_dir
  }

  # Where to find Gitea. The load balancers get their hostnames a little after helmfile returns.
  after_hook "wait_for_load_balancers" {
    commands = ["apply"]
    execute  = ["kubectl", "--context", local.kube_context, "--namespace", "gitea", "wait", "ingress/gitea", "service/gitea-ssh", "--for=jsonpath={.status.loadBalancer.ingress}", "--timeout=600s"]
  }

  # The load balancers' own hostnames, read from the Ingress and Service status.
  after_hook "print_gitea_endpoints" {
    commands = ["apply"]
    execute = [
      "kubectl", "--context", local.kube_context, "--namespace", "gitea", "get", "ingress/gitea", "service/gitea-ssh",
      "--output", "go-template={{range .items}}{{$lb := (index .status.loadBalancer.ingress 0).hostname}}{{if eq .kind \"Ingress\"}}Gitea: http://{{$lb}}/{{else}}SSH: git@{{$lb}}{{end}}{{\"\\n\"}}{{end}}",
    ]
  }

  before_hook "kubeconfig" {
    commands = ["destroy"]
    execute = concat([
      "aws", "eks", "update-kubeconfig",
      "--name", dependency.state.outputs.name,
      "--region", local.account.aws_region,
      "--alias", local.kube_context,
      ], get_env("GITHUB_ACTIONS", "") == "true" ? [] : [
      "--role-arn", "arn:aws:iam::${local.account.account_id}:role/${dependency.state.outputs.role_names.platform_eks_admin}",
    ])
    if = anytrue([
      for cmd in local.check_cluster ? ["check"] : [] :
      trimspace(run_cmd("--terragrunt-quiet", "aws", "eks", "list-clusters",
        "--region", local.account.aws_region,
        "--query", "contains(clusters, '${dependency.state.outputs.name}')",
      "--output", "text")) == "True"
    ])
  }

  # Releases in reverse dependency order, Gitea first. The Ingress and the SSH Service carry the
  # Auto Mode load balancer controller's finalizers, so --deleteWait returns only once the ALB and
  # NLB are deleted in AWS; otherwise they would block the VPC destroy. --skip-charts: uninstall
  # needs no chart downloads.
  before_hook "helmfile_destroy" {
    commands    = ["destroy"]
    execute     = concat(local.helmfile, ["destroy", "--skip-charts", "--deleteWait", "--deleteTimeout", "900"])
    working_dir = local.helmfile_dir
    if = anytrue([
      for cmd in local.check_cluster ? ["check"] : [] :
      trimspace(run_cmd("--terragrunt-quiet", "aws", "eks", "list-clusters",
        "--region", local.account.aws_region,
        "--query", "contains(clusters, '${dependency.state.outputs.name}')",
      "--output", "text")) == "True"
    ])
  }
}
