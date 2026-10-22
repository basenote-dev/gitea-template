# ADR 0003: Bootstrap, and how pipelines and people get in

Status: accepted, 2026-10-21

## Decision

No AWS keys are stored anywhere, and no person's role is written into the cluster. A one-time
bootstrap, run from a laptop with admin credentials, creates what the pipeline needs to log in.

```sh
cd bootstrap
GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
```

## What the bootstrap creates

Names start with `gitea-<suffix>`, a random suffix picked on the first apply. The bucket and the
OIDC provider are the exceptions.

| What | Name | Why |
| --- | --- | --- |
| S3 bucket | `gitea-tfstate-<account>-<region>` | OpenTofu state |
| KMS key | `alias/gitea-<suffix>-tofu-state` | Encrypts state and plan files |
| OIDC provider | `token.actions.githubusercontent.com` | Lets AWS trust GitHub's tokens |
| IAM role | `gitea-<suffix>-github-plan` | Plans: read-only, plus the state lock, state key and secrets |
| IAM role | `gitea-<suffix>-github-apply` | Deploys: admin |
| IAM role | `gitea-<suffix>-platform-eks-admin` | People's way into the cluster |
| Secrets | `gitea-<suffix>/db`, `/valkey`, `/admin`, `/metrics`, `/ssh-host-key`, `/app-ini-keys` | Random values, written write-only |
| GitHub environments | `sandbox-plan`, `sandbox-apply` (`main` only) | Each holds `AWS_ROLE_ARN` for its role |
| GitHub variable | `BOOTSTRAPPED=true` | Turns the workflow on |

## How the pipeline logs in

Each job gets a signed GitHub token and trades it with AWS STS for credentials that last about
an hour. The role's trust policy checks the token's `sub`, which names the repo by its numeric
IDs and the environment. Another repo, a fork, or a recreated repo with the same name gets
refused. Only `main` can use `sandbox-apply`, so a pull request can plan but only a merge can
deploy.

## How the cluster is reached

The cluster uses EKS access entries and has no `aws-auth` ConfigMap.

| Role | Access | Used by |
| --- | --- | --- |
| `github-apply` | Cluster admin | Deploys |
| `github-plan` | Read-only | `helmfile diff` in plans |
| `platform-eks-admin` | Cluster admin | People |

A person runs the `kubeconfig_command` the stack prints, which assumes `platform-eks-admin`.
Anyone in the account whose IAM policy allows `sts:AssumeRole` on it can use it. Using one
shared role keeps SSO role ARNs, which change when permission sets are rebuilt, out of the
cluster. CloudTrail still records who assumed it.

## Trade-offs

- `github-apply` is a full admin to keep the demo simple. Production would scope it.
- Every account admin gets cluster admin. Production would add a read-only role.
