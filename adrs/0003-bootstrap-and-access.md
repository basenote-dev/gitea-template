# ADR 0003: The bootstrap, and how pipelines and people get in

Status: accepted, 2026-10-21

## The problem

GitHub Actions needs to deploy into AWS. People need `kubectl` on the cluster. We don't want
AWS keys stored anywhere, and we don't want anyone's personal or SSO role written into the
cluster config.

But something has to exist before the first pipeline run. It needs a role to log in as, a
place to keep state, and passwords to deploy with. That's what the bootstrap creates. It runs
once, from a laptop, with admin credentials.

```sh
cd bootstrap
GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
```

## What the bootstrap creates

All of it is in `bootstrap/state/main.tf`.

The first apply picks a random 6-character suffix and keeps it in state. Every name below
except the bucket and the OIDC provider starts with `gitea-<suffix>`, for example
`gitea-3f9a1c-github-plan` and `gitea-3f9a1c/db`. The rest of this document drops the prefix.
Several names stay taken after a teardown: a KMS alias while its key waits out the deletion
window, and roles or log groups that a cleanup tool missed. A rebuild with fixed names failed
with `AlreadyExists` on them. With the suffix, a new build never collides with an old one.

### In AWS

| What | Name | Why |
| --- | --- | --- |
| S3 bucket | `gitea-tfstate-<account>-<region>` | Holds OpenTofu state. Terragrunt creates it empty (`--backend-bootstrap`), then this unit adopts it and locks it down: versioning, encryption, no public access, TLS only |
| KMS key | `alias/gitea-<suffix>-tofu-state` | Encrypts state and plan files. Has `prevent_destroy`, so a teardown never deletes it by accident |
| GitHub OIDC provider | `token.actions.githubusercontent.com` | Lets AWS trust tokens that GitHub signs. Skipped with `USE_EXISTING_GITHUB_OIDC_PROVIDER=true` if the account already has one |
| IAM role | `gitea-<suffix>-github-plan` | Pipeline plans. Read-only, plus the state lock file, the state key, and reading `gitea/*` secrets |
| IAM role | `gitea-<suffix>-github-apply` | Pipeline deploys. Admin |
| IAM role | `gitea-<suffix>-platform-eks-admin` | People's way into the cluster |
| Secrets | `gitea-<suffix>/db`, `/valkey`, `/admin`, `/metrics` | Random passwords. Write-only, so they never land in state or plan output |
| Secret | `gitea-<suffix>/ssh-host-key` | One SSH host key for every pod |
| Secret | `gitea-<suffix>/app-ini-keys` | Gitea's four signing keys, shared by every pod |

### In GitHub (only when `GITHUB_TOKEN` is set)

| What | Why |
| --- | --- |
| Environment `sandbox-plan` | Plans run here, from any branch |
| Environment `sandbox-apply` | Deploys run here. Only `main` may use it |
| Variable `AWS_ROLE_ARN` in each environment | Tells the workflow which role to assume. `github-plan` in one, `github-apply` in the other |
| Repo variable `BOOTSTRAPPED=true` | Turns the workflow on. Without it, every job is skipped |

Nothing here holds a secret. The ARNs are not secrets.

## How a pipeline logs in

No AWS keys are stored in GitHub. Each run gets short-lived credentials instead.

1. The job declares `environment: sandbox-apply` (or `sandbox-plan`) and `id-token: write`.
2. GitHub gives the job a signed token. Its `sub` claim names the repo and the environment,
   for example `repo:basenote-dev@<id>/gitea-deployment@<id>:environment:sandbox-apply`.
3. `configure-aws-credentials` sends that token to AWS STS and asks for `vars.AWS_ROLE_ARN`.
4. STS checks the token against the OIDC provider. Then it checks the role's trust policy:
   `aud` must be `sts.amazonaws.com`, and `sub` must match exactly.
5. STS returns credentials that last about an hour.

The `sub` check is what keeps other repos out. A fork, or another repo in the same org, sends a
different `sub`, so STS refuses it. A pull request branch can't use `sandbox-apply`, because
GitHub only lets `main` deploy to that environment. So a PR can plan, but only a merge can
deploy.

The `sub` uses the repo's numeric IDs, not just its name. If someone deletes the repo and
creates a new one with the same name, it gets new IDs, and the old trust doesn't match it.
That's also why a recreated repo has to run the bootstrap again.

## How the pipeline reaches the cluster

The cluster uses EKS access entries (`authentication_mode = "API"`). There's no `aws-auth`
ConfigMap. Creating the cluster doesn't make anyone an admin.

`aws/main.tf` gives three roles an access entry:

| Role | Cluster access | Used by |
| --- | --- | --- |
| `github-apply` | `AmazonEKSClusterAdminPolicy` | Deploys: Helmfile installs and upgrades the charts |
| `github-plan` | `AmazonEKSAdminViewPolicy` (read-only) | Plans: `helmfile diff` reads the live releases |
| `platform-eks-admin` | `AmazonEKSClusterAdminPolicy` | People |

The stack looks the roles up by name (`data "aws_iam_role"`). If the bootstrap hasn't run, the
plan fails right away instead of building a cluster no one can reach.

In CI, the Terragrunt hook runs `aws eks update-kubeconfig` with no extra role. The job is
already `github-apply` or `github-plan`, and each has its own access entry.

## How a person gets `kubectl`

People never get their own access entry. They all go through `platform-eks-admin`.

1. Log in to the account as any admin, for example through SSO.
2. Run the command the stack prints as `kubeconfig_command`:
   ```sh
   aws eks update-kubeconfig --region us-west-2 --name gitea-<suffix> \
     --role-arn arn:aws:iam::<account>:role/gitea-<suffix>-platform-eks-admin
   ```
3. Each `kubectl` call now runs `aws eks get-token --role-arn ...`. The AWS CLI assumes
   `platform-eks-admin` with your session, gets a token, and EKS maps that role to cluster
   admin.

The role trusts the account itself (`arn:aws:iam::<account>:root`). In practice that means
anyone in the account whose own IAM policy allows `sts:AssumeRole` on it. Admins have that.
Nobody outside the account does.

On a laptop, the Terragrunt hook adds the same `--role-arn` automatically. That's how method 1
runs Helmfile without its own access entry.

Why a shared role instead of each person's SSO role:
- SSO role ARNs have generated suffixes and change when permission sets are rebuilt. An access
  entry pointing at one breaks silently.
- The cluster config doesn't name any person, so adding or removing people never touches it.
- CloudTrail still records who called `AssumeRole`, so you can tell people apart.

## The whole chain

```
laptop admin ──bootstrap──▶ OIDC provider, github-plan, github-apply, platform-eks-admin,
                            state bucket + key, secrets, GitHub environments + variables

PR      ──GitHub token (sandbox-plan)──▶ STS ──▶ github-plan  ──▶ tofu plan, helmfile diff (view)
merge   ──GitHub token (sandbox-apply)─▶ STS ──▶ github-apply ──▶ tofu apply, helmfile apply (admin)

person (admin in the account) ──AssumeRole──▶ platform-eks-admin ──access entry──▶ kubectl (admin)
```

## What we learned in a second account

The bootstrap failed the first time in a new account. Another project had already created
GitHub's OIDC provider there, and AWS allows only one per URL. We didn't want to adopt it, since
our teardown would then delete it. Now `USE_EXISTING_GITHUB_OIDC_PROVIDER=true` makes our roles
trust the existing provider without managing it. After that, plans, deploys, both upgrades and
the destroy all logged in over OIDC, and `kubectl` worked through `platform-eks-admin`.

## Trade-offs

- `github-apply` is a full admin. That keeps the demo simple. Production would limit it to
  the services the stack uses.
- `platform-eks-admin` is cluster admin for anyone who's an account admin. Production would
  add a read-only role for most people.
- The bootstrap runs from a laptop with admin keys. Something has to create the first role,
  so this can't come from the pipeline itself.
