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
# root.hcl generates the backend, the AWS provider (region, account guard, cost tags from
# account.hcl) and state encryption.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals

  cluster_name = "gitea" # local.name in main.tf
  kube_context = "gitea-${local.account.account_name}"
  helmfile_dir = "${get_repo_root()}/helmfile"

  # Does the EKS cluster exist yet? Asked only for plan and destroy (a fresh account has nothing
  # to diff or uninstall); the for expression keeps run_cmd from running for other commands.
  cluster_exists = anytrue([
    for cmd in contains(["plan", "destroy"], get_terraform_command()) ? ["check"] : [] :
    trimspace(run_cmd("--terragrunt-quiet", "aws", "eks", "list-clusters",
      "--region", local.account.aws_region,
      "--query", "contains(clusters, '${local.cluster_name}')",
    "--output", "text")) == "True"
  ])

  # Writes the cluster to ~/.kube/config as context gitea-sandbox. In CI the job's own role has
  # an EKS access entry (github-plan view, github-apply admin). On a laptop the caller is any
  # admin in the account, so kubectl assumes platform-eks-admin (created by bootstrap, trusted by
  # the account) instead of needing its own access entry.
  kubeconfig = concat([
    "aws", "eks", "update-kubeconfig",
    "--name", local.cluster_name,
    "--region", local.account.aws_region,
    "--alias", local.kube_context,
    ], get_env("GITHUB_ACTIONS", "") == "true" ? [] : [
    "--role-arn", "arn:aws:iam::${local.account.account_id}:role/platform-eks-admin",
  ])

  # Helmfile reads this stack's outputs itself (helmfile/values/tofu-outputs.yaml.gotmpl).
  helmfile = ["helmfile", "--no-color", "--environment", local.account.account_name, "--kube-context", local.kube_context]
}

# Ordering only (no outputs used): on a laptop, run --all applies state/ first.
dependencies {
  paths = ["../state"]
}

terraform {
  # Terragrunt runs from a cache copy: copy the whole repo (note the //) so ../modules resolves.
  source = "${get_repo_root()}//aws"

  # Plans wait for a running apply's state lock instead of failing.
  extra_arguments "lock_timeout" {
    commands  = get_terraform_commands_that_need_locking()
    arguments = ["-lock-timeout=20m"]
  }

  after_hook "kubeconfig" {
    commands = ["apply", "plan"]
    execute  = local.kubeconfig
    if       = get_terraform_command() == "apply" || local.cluster_exists
  }

  # What Helm would change, shown in the plan output (and the PR comment in CI).
  after_hook "helmfile_diff" {
    commands    = ["plan"]
    execute     = concat(local.helmfile, ["diff", "--context", "5", "--suppress-secrets", "--skip-diff-on-install"])
    working_dir = local.helmfile_dir
    if          = local.cluster_exists
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
    execute  = local.kubeconfig
    if       = local.cluster_exists
  }

  # Releases in reverse dependency order, Gitea first. The Ingress and the SSH Service carry the
  # Auto Mode load balancer controller's finalizers, so --deleteWait returns only once the ALB and
  # NLB are deleted in AWS; otherwise they would block the VPC destroy. --skip-charts: uninstall
  # needs no chart downloads.
  before_hook "helmfile_destroy" {
    commands    = ["destroy"]
    execute     = concat(local.helmfile, ["destroy", "--skip-charts", "--deleteWait", "--deleteTimeout", "900"])
    working_dir = local.helmfile_dir
    if          = local.cluster_exists
  }
}
