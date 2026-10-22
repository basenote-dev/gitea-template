# What we built

What exists in this repo and in AWS, and where. Why each piece exists is in
[architecture decisions](../../adrs/0001-architecture-decisions.md).

## Layout

| Folder | What's in it |
| --- | --- |
| `aws/` | OpenTofu for everything in AWS: VPC, EKS, RDS, Valkey, EFS, IAM for the add-ons |
| `helmfile/` | Everything inside the cluster: External Secrets, two small charts of ours, Gitea |
| `bootstrap/` | Terragrunt: the one-time `state/` unit and the `gitea/` unit that runs `aws/` and Helmfile |
| `modules/` | terraform-aws-modules, copied in at pinned versions |
| `scripts/` | The zero-downtime health check |
| `.github/workflows/` | Plan on pull requests, deploy on merge to `main` |

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

## Cluster access

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

## Pieces we added to stock modules and charts

Everything else is off the shelf: the modules in `modules/`, the official Gitea and External
Secrets charts, EKS Auto Mode and stock GitHub Actions.

### Bootstrap (`bootstrap/state/`)

| What | Why |
| --- | --- |
| Random name suffix: every AWS name starts with `gitea-<suffix>` | Some names stay taken after a teardown, like a KMS alias whose key is waiting to be deleted. A rebuild with fixed names failed with `AlreadyExists` |
| State bucket adopted with an `import` block | The bucket has to exist before any state does, so Terragrunt creates it and this unit then manages it |
| State KMS key with `prevent_destroy` | Encrypts the gitea unit's state and plan files. KMS keys can't be deleted at once, so a teardown never touches it |
| CI roles with a hand-written OIDC trust | Each role trusts one GitHub environment of this repo by its numeric IDs. The module's built-in option checks `aud` loosely |
| `USE_EXISTING_GITHUB_OIDC_PROVIDER` | AWS allows one GitHub OIDC provider per account, and another project may own it |
| `platform-eks-admin` role | People reach the cluster through it, so no SSO role is written into the cluster |
| Random secrets, written write-only | Passwords and keys never appear in Git, state or plan output |
| Existing GitHub variables imported | GitHub rejects a create for a variable that already exists, which happens when a repo is bootstrapped twice |

### Terragrunt (`bootstrap/`)

| What | Why |
| --- | --- |
| `dependency "state"` in the gitea unit | Names are random, so the gitea unit reads the suffix, key and role names from `state/` |
| Hooks for kubeconfig and Helmfile | One command deploys AWS and the cluster, with no deploy script |
| Cluster check before plan and destroy hooks | A fresh account has no cluster to diff or uninstall |
| Repo name read from the git remote | A copy of the template trusts its own repo without edits |
| `EXPECTED_ACCOUNT_ID` | Optional guard against deploying to the wrong account |

### AWS (`aws/main.tf`)

| What | Why |
| --- | --- |
| Valkey as plain resources | The module only takes `auth_token`, which would store the token in state |
| CloudWatch add-on and its log groups as plain resources | OpenTofu owns the log groups, so a destroy removes them |
| External Secrets policy written by hand | It reads only the six Gitea secrets |
| One security group per data store | Postgres, Valkey and NFS accept only the cluster |
| `rds.force_ssl` with `apply_method = "pending-reboot"` | TLS-only database, without a change in every plan |
| EFS access point at `/gitea`, uid/gid 1000 | Pods see only Gitea's folder, as the Gitea user |

### Helmfile (`helmfile/`)

| What | Why |
| --- | --- |
| Values read from `terragrunt output` | Endpoints and secret names come from OpenTofu, with nothing copied by hand |
| `charts/gitea-cluster` | Namespace with readiness gates, the EFS volume and the ALB IngressClass |
| `charts/gitea-config` | External Secrets for the admin user, `app.ini` secrets and SSH key, plus the EFS claim |
| Patch: `preStop: sleep 60` | The Gitea chart has no setting for it |
| Patch: per-pod mount off the first init container | Fixes a mount race on a fresh install |

### Pipeline and tooling

| What | Why |
| --- | --- |
| `BOOTSTRAPPED` check on every job | A repo that hasn't run the bootstrap runs nothing |
| helm-diff pinned through mise | Same plugin version on laptops and in CI |
| `scripts/zero-downtime-upgrade-healthcheck.sh` | Counts failed requests during an upgrade |
