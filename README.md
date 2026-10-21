# gitea-template

Gitea on AWS: EKS Auto Mode, RDS PostgreSQL, ElastiCache Valkey and EFS, deployed with
OpenTofu, Terragrunt and Helmfile.

```
aws/         OpenTofu: VPC, EKS, RDS, Valkey, EFS
helmfile/    everything inside the cluster (Gitea, External Secrets, node pool)
bootstrap/   Terragrunt config that ties it together, plus the one-time state/ setup
.mise.toml   pinned tool versions (mise install)
modules/     vendored terraform-aws-modules
```

## Before you start

- Admin AWS credentials for an empty AWS account in your shell (`aws sts get-caller-identity`).
- The AWS CLI, git and [mise](https://mise.jdx.dev). For method 2 also `gh`.

## Method 1: everything from your laptop

```sh
git clone https://github.com/basenote-dev/gitea-template.git && cd gitea-template/bootstrap
mise install
terragrunt run --all apply --backend-bootstrap
```

1. `mise install` installs the pinned OpenTofu, Terragrunt, Helm, Helmfile and kubectl.
2. `terragrunt run --all apply` runs two units in order:
   - `state/`: the S3 state bucket (Terragrunt creates it because of `--backend-bootstrap`), the
     KMS key that encrypts all other state, the CI roles, the `platform-eks-admin` role and the
     `gitea/*` secrets.
   - `gitea/`: the OpenTofu in `aws/` (about 20 minutes), then Helmfile installs Gitea.
3. At the end it prints the Gitea URL and the SSH host.

Tear down with `terragrunt run --all destroy` (keeps `state/`).

## Method 2: bootstrap from your laptop, then GitHub Actions deploys

```sh
git clone <your fork> && cd <your fork>/bootstrap
mise install
GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
```

1. This runs only `state/`. With `GITHUB_TOKEN` set it also sets up GitHub: the OIDC trust,
   the environments `sandbox-plan` (read-only role, any branch) and `sandbox-apply` (admin role,
   `main` only), and the repository variable `BOOTSTRAPPED`. No AWS keys are stored in GitHub.
2. Start the first deploy: Actions -> Gitea Deploy -> Run workflow -> `apply`, or push to `main`.
3. After that, every pull request gets a plan comment (OpenTofu plan and Helm diff), and every
   merge to `main` applies it.

The workflow does nothing in a repository without `BOOTSTRAPPED` (a fresh clone, or this
template), so pushing before the bootstrap is harmless. Deleting the variable turns CI off
again; running the bootstrap sets it back.

Tear down with Actions -> Gitea Deploy -> Run workflow -> `destroy` (keeps `state/`).

## Watch a zero-downtime upgrade

Run this from your laptop, with the same AWS credentials, while a rollout happens:

```sh
scripts/zero-downtime-upgrade-healthcheck.sh
```

It needs only the AWS CLI, git and curl. It finds Gitea's load balancers by their tags, logs in
as the admin with the password from Secrets Manager, and creates a test repository and a
temporary SSH key. Five loops then hit Gitea every 1-3 seconds: `/api/healthz`, `git ls-remote` over HTTP and over SSH, a commit pushed over SSH,
and an issue created through the API. Every 5 seconds it prints one line with each check's
latest result and its ok/fail count:

```
04:12:20  healthz ok       9/0  https-ls-remote ok       3/0  ssh-ls-remote ok       3/0  ssh-push ok       2/0  api-write ok       3/0
```

Start it, merge an upgrade PR (change `gitea_version` in `aws/main.tf`), and watch the counts
while the pods roll. Ctrl-C prints the totals and the time of any failure; every result is
kept in `zero-downtime-healthcheck-<time>.log`.
