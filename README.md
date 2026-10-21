# gitea-template

Gitea on AWS with zero-downtime upgrades: EKS Auto Mode, RDS PostgreSQL, ElastiCache Valkey and
EFS, deployed with OpenTofu, Terragrunt and Helmfile.

```
aws/         OpenTofu: VPC, EKS, RDS, Valkey, EFS
helmfile/    everything inside the cluster (Gitea, External Secrets)
bootstrap/   Terragrunt config that ties it together, plus the one-time state/ setup
scripts/     the zero-downtime health check
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

Tear down with `terragrunt run --all destroy` (keeps `state/`).

## Method 2: bootstrap from your laptop, then GitHub Actions deploys

```sh
git clone <your copy of this repo> && cd <it>/bootstrap
mise install
GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
```

Then start the first deploy: Actions -> Gitea Deploy -> Run workflow -> `OpenTofu Apply`.
After that, every pull request gets a plan comment (OpenTofu plan and Helm diff), and every
merge to `main` deploys it. Tear down with Run workflow -> `OpenTofu Destroy`.

The workflow does nothing in a repository the bootstrap hasn't run for (a fresh clone, or this
template), so pushing first is harmless.

## What `terragrunt run --all apply` does

1. Terragrunt creates the S3 bucket for OpenTofu state (`--backend-bootstrap`).
2. The `state/` unit creates the KMS key that encrypts the state, the GitHub OIDC roles, the
   `platform-eks-admin` role for `kubectl`, and the `gitea/*` secrets with random values. With
   `GITHUB_TOKEN` set, it also adds the GitHub environments and variables.
3. The `gitea/` unit runs the OpenTofu in `aws/`: VPC, EKS Auto Mode cluster, RDS PostgreSQL,
   Valkey, EFS (about 20 minutes).
4. Its hook runs `helmfile apply`: External Secrets (copies the secrets into the cluster), the
   EFS volume and load balancer settings, then Gitea with 2 pods.
5. It prints the Gitea URL and SSH host.

## What a Gitea upgrade does

1. Change `gitea_version` in `aws/main.tf` in a pull request, one release at a time
   (1.26.3 -> 1.26.4 -> 1.27.3 -> 28.2.0).
2. The PR's plan comment shows the change. Merge it.
3. Helm starts one new pod. The load balancers send it traffic only after it passes their
   health checks.
4. Then one old pod is told to stop. It keeps serving for 60 seconds while the load balancers
   move traffic off it, then finishes its open git operations and exits.
5. The same happens for the second pod. One pod is always serving.
6. On a minor or major upgrade, the first new pod updates the database tables when it starts.
   The old pod keeps working while that happens.

Both pods share the same data, which is why the upgrade can swap them one at a time: repos on
EFS, users and issues in RDS, sessions and cache in Valkey, and one SSH host key from Secrets
Manager.

To roll back, don't lower the version (Gitea can't run on tables a newer version changed).
Restore the database with RDS point-in-time recovery to a minute before the upgrade.

Why it is built this way (two pods, EFS, Valkey, the shared SSH key) is in
[adrs/0001-zero-downtime-gitea.md](adrs/0001-zero-downtime-gitea.md). Every piece we built ourselves, on top of
the off-the-shelf modules and charts, is listed in [adrs/0002-what-we-built.md](adrs/0002-what-we-built.md).

## Watch a zero-downtime upgrade

Run this from your laptop, with the same AWS credentials, while a rollout happens:

```sh
scripts/zero-downtime-upgrade-healthcheck.sh
```

It needs only the AWS CLI, git and curl. It finds Gitea's load balancers by their tags, logs in
as the admin with the password from Secrets Manager, and creates a test repository and a
temporary SSH key. Five loops then hit Gitea every 1-3 seconds: `/api/healthz`, `git ls-remote`
over HTTP and over SSH, a commit pushed over SSH, and an issue created through the API. Every
5 seconds it prints one line with each check's latest result and its ok/fail count:

```
04:12:20  healthz ok       9/0  https-ls-remote ok       3/0  ssh-ls-remote ok       3/0  ssh-push ok       2/0  api-write ok       3/0
```

Start it, merge an upgrade PR, and watch the counts while the pods roll. Ctrl-C prints the
totals and the time of any failure; every result is kept in
`zero-downtime-healthcheck-<time>.log`.

## Running cost

About $0.60 an hour (about $14 a day) while the cluster is up, at us-west-2 on-demand list
prices. Tear it down when you're not using it; the bootstrap that stays behind costs about $3 a
month (the state key and the secrets).

| Piece | Per hour |
| --- | --- |
| RDS PostgreSQL `db.m7g.large`, single AZ, 20 GB | ~$0.17 |
| ElastiCache Valkey `cache.m7g.large`, 1 node | ~$0.13 |
| EKS control plane | $0.10 |
| EC2 nodes run by Auto Mode (usually 1 to 2 `c6a.large`) plus the Auto Mode fee | ~$0.09 to $0.17 |
| NAT gateway | ~$0.05 |
| ALB and NLB | ~$0.05 |
| EFS, CloudWatch logs, data transfer | a few cents |

Multi-AZ RDS would add about $0.17 an hour.

## Demo limitations

This demo is about one thing: upgrading Gitea without downtime. Everything Gitea needs for
that runs in two copies or lives outside the pods. The pieces below are kept single and simple
to save cost; none of them is touched by a Gitea upgrade, and each has a known fix for
production.

- The database is in one AZ. AWS maintenance or a failure takes it offline for a few minutes,
  and Gitea fails requests until it is back. Gitea upgrades don't touch it. Multi-AZ
  (`db_multi_az = true`) cuts that to about 40 seconds; RDS Proxy in front would turn those
  40 seconds into slow requests instead of errors.
- Valkey is a single node. If it restarts, users are logged out and queued jobs are lost.
- HTTP only, on the load balancers' own hostnames. A domain would add HTTPS and a real SSH
  clone URL (Gitea's UI shows `git@localhost:...` without one).
- Auto Mode's EC2 nodes don't carry the cost-allocation tags.
