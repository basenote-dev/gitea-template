# gitea-template

Gitea on AWS with zero-downtime upgrades: EKS Auto Mode, RDS PostgreSQL, ElastiCache Valkey and
EFS, deployed with OpenTofu, Terragrunt and Helmfile.

```
aws/         OpenTofu: VPC, EKS, RDS, Valkey, EFS
helmfile/    everything inside the cluster (Gitea, External Secrets)
bootstrap/   Terragrunt config that ties it together, plus the one-time state/ setup
scripts/     the zero-downtime health check
adrs/        architecture decision records
docs/        reference docs, diagrams
.mise.toml   pinned tool versions (mise install)
modules/     vendored terraform-aws-modules
```

## Documentation

| Kind | Where | Read it to |
| --- | --- | --- |
| Tutorial | This README, from "Get your own copy" to "Method 2" | Deploy Gitea the first time |
| How-to guides | This README: "Upgrade Gitea", "Tear down" | Upgrade without downtime, remove everything |
| Reference | [Requirements](docs/reference/requirements.md), [What we built](docs/reference/what-we-built.md) | See what the assignment asked for and what exists |
| Explanation | [Architecture decisions](adrs/0001-architecture-decisions.md) | Understand why it's built this way |

## Before you start

- Admin AWS credentials for an empty AWS account in your shell (`aws sts get-caller-identity`).
- Every command below sets `AWS_REGION=us-west-2`. To use another region, change it the same
  way in every command, including the health check and the teardown.
- The AWS CLI, git and [mise](https://mise.jdx.dev) installed. For method 2 also `gh`.
- mise only reads a repo's `.mise.toml` after you trust it. Until then it prints
  `mise WARN ... .mise.toml is not trusted` and installs nothing, so every method below runs
  `mise trust` first.
- If the account already has a GitHub OIDC provider from another project, set
  `USE_EXISTING_GITHUB_OIDC_PROVIDER=true`. AWS allows only one, and we reuse it without
  managing it. Check with `aws iam list-open-id-connect-providers`.

## Get your own copy

Deploy from your own repo, not from this template. Pull requests and deploys then happen in
your repo, and the template stays as it is.

Set your GitHub username (or organization) once. Every command below uses it:

```sh
export GH_USERNAME=<your-github-username>
```

Start a new repo from the template (creates the repo on GitHub and clones it):

```sh
gh repo create $GH_USERNAME/gitea-deployment --template basenote-dev/gitea-template --private --clone
cd gitea-deployment
```

Or, if you already created an empty repo on GitHub, copy the template into it:

```sh
git clone https://github.com/$GH_USERNAME/gitea-deployment.git
cd gitea-deployment
git remote add template https://github.com/basenote-dev/gitea-template.git
git pull template main
git push -u origin main
```

Run everything below from that folder.

## Method 1: everything from your laptop

First, log in to the AWS account you're deploying to, as an admin. Use an SSO profile:

```sh
aws sso login --profile <your-aws-profile>
export AWS_PROFILE=<your-aws-profile>
```

Or access keys:

```sh
export AWS_ACCESS_KEY_ID=<your-access-key-id>
export AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
```

Check that the account ID it prints is the one you want:

```sh
aws sts get-caller-identity
```

Then deploy:

```sh
mise trust
mise install
cd bootstrap
AWS_REGION=us-west-2 terragrunt run --all apply --backend-bootstrap --non-interactive
```

`--non-interactive` skips Terragrunt's "run apply in each unit?" prompt. `run --all` already
auto-approves each OpenTofu apply.

To remove it, see [Tear down](#tear-down).

## Method 2: bootstrap from your laptop, then GitHub Actions deploys

First, log in to the AWS account you're deploying to, as an admin. Use an SSO profile:

```sh
aws sso login --profile <your-aws-profile>
export AWS_PROFILE=<your-aws-profile>
```

Or access keys:

```sh
export AWS_ACCESS_KEY_ID=<your-access-key-id>
export AWS_SECRET_ACCESS_KEY=<your-secret-access-key>
```

Check that the account ID it prints is the one you want:

```sh
aws sts get-caller-identity
```

Also log in to GitHub. The bootstrap uses your token to create the repo's environments and
variables, so it needs admin access to your repo:

```sh
gh auth login
```

Then bootstrap:

```sh
mise trust
mise install
cd bootstrap
AWS_REGION=us-west-2 GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap --non-interactive -auto-approve
```

`-auto-approve` skips OpenTofu's "Enter a value: yes" prompt, and `--non-interactive` skips
Terragrunt's own prompts.

The bootstrap only sets up the account and the repo. Nothing is deployed yet. Start the
first deploy once, from GitHub Actions:

```sh
gh workflow run deploy.yml -R $GH_USERNAME/gitea-deployment -f action="OpenTofu Apply"
gh run watch -R $GH_USERNAME/gitea-deployment
```

(Or in the browser: Actions -> Gitea Deploy -> Run workflow -> `OpenTofu Apply`.) It runs the
same apply as method 1 and takes about 25 minutes. The run's summary shows the Gitea URL and
SSH host.

From then on, changes go through pull requests: each PR gets a plan comment (OpenTofu plan and
Helm diff), and each merge to `main` deploys it. To remove it, see [Tear down](#tear-down).

### What turns the pipeline on

Every job in the workflow first checks the repo variable `BOOTSTRAPPED`. If it isn't `true`,
the job is skipped. That's why a push to a fresh copy, or to this template, shows every job as
skipped.

You never set it by hand. The bootstrap command above creates it through the GitHub API (with
your `GITHUB_TOKEN`), together with the `sandbox-plan` and `sandbox-apply` environments and their
`AWS_ROLE_ARN` variables. They're repo settings, not files, so they don't show up as commits.
To see them: your repo -> Settings -> Secrets and variables -> Actions -> Variables tab, or:

```sh
gh variable list -R $GH_USERNAME/gitea-deployment
```

A run that was skipped before the bootstrap runs for real if you re-run it afterwards, because
a re-run checks `BOOTSTRAPPED` again.

## What `terragrunt run --all apply` does

![The seven steps of terragrunt run --all apply, in order](docs/images/deploy-flow.svg)

Terragrunt creates nothing itself. It writes a few files into each unit, runs `tofu` in the
units in the right order, and runs commands before and after (hooks). There are two units:
`state/` runs first and `gitea/` second, because `gitea/` reads `state/`'s outputs. With method
2, you run step 2 from your laptop and GitHub Actions runs steps 3 and 4.

1. Terragrunt creates the empty S3 bucket for OpenTofu state (`--backend-bootstrap`).
2. `state/` runs `tofu apply` on `bootstrap/state/`, which takes about a minute. It creates:
   - A random suffix. Every AWS name below starts with `gitea-<suffix>`, so a rebuild never
     collides with names an earlier build left behind.
   - The KMS key that encrypts the gitea unit's state.
   - The GitHub OIDC provider and the `github-plan` and `github-apply` roles.
   - The `platform-eks-admin` role for `kubectl`.
   - The Secrets Manager secrets, with random values: database password, Valkey token, admin
     password, metrics token, SSH host key and Gitea's signing keys.
   - With `GITHUB_TOKEN` set, the GitHub environments and variables.
3. `gitea/` reads those outputs (suffix, key, role names), then runs `tofu apply` on `aws/`,
   which takes about 20 minutes. It creates the VPC, the EKS Auto Mode cluster, RDS
   PostgreSQL, Valkey and EFS. RDS and Valkey read their passwords from the secrets made in
   step 2, which is why `state/` has to run first.
4. Hooks in `bootstrap/gitea/terragrunt.hcl` run after that apply:
   1. `aws eks update-kubeconfig` adds the cluster to `~/.kube/config`.
   2. `helmfile apply` installs External Secrets (it copies the secrets into the cluster), the
      EFS volume and load balancer settings, then Gitea with 2 pods.
   3. `kubectl wait` waits for the load balancers, then the URL and SSH host are printed.

### Where the Terragrunt config lives

Three files hold all of it. Read them in this order:

1. `bootstrap/root.hcl` is shared by both units. `remote_state` says which bucket holds state,
   and `generate "provider"` writes the AWS provider into each unit.
2. `bootstrap/state/terragrunt.hcl`: `terraform { source }` says which OpenTofu folder the unit
   runs, and `inputs` are the variables it passes.
3. `bootstrap/gitea/terragrunt.hcl` does the same for the gitea unit. It also has
   `dependency "state"` (reads `state/`'s outputs, so `state/` runs first),
   `generate "encryption"`, and the hooks from step 4.

## Upgrade Gitea

![Gitea's two pods, the secrets they get from Secrets Manager, and the services those secrets unlock](docs/images/runtime.svg)

An upgrade is a change to one line: `version` under `gitea` in
[`helmfile/env/sandbox.yaml`](helmfile/env/sandbox.yaml). Go one release at a time: 1.26.3 -> 1.26.4 -> 1.27.3 -> 28.2.0.

### Method 1: from your laptop

```sh
sed -i '' 's/version: "1.26.3"/version: "1.26.4"/' helmfile/env/sandbox.yaml   # GNU sed: -i without ''
cd bootstrap
AWS_REGION=us-west-2 terragrunt run --all apply --non-interactive
```

Only the Helm release changes, so the apply takes a few minutes.

Watch the upgrade: before you run the apply, start the health check in a second terminal, with
the same AWS credentials and region:

```sh
AWS_REGION=us-west-2 scripts/zero-downtime-upgrade-healthcheck.sh
```

### Method 2: with a pull request

```sh
git checkout -b upgrade-gitea-1.26.4
sed -i '' 's/version: "1.26.3"/version: "1.26.4"/' helmfile/env/sandbox.yaml   # GNU sed: -i without ''
git commit -am "Upgrade Gitea 1.26.3 to 1.26.4"
git push -u origin upgrade-gitea-1.26.4
gh pr create --fill
gh pr checks --watch
```

The pull request runs the plan job, which comments the OpenTofu plan and the Helm diff on the
PR. For an upgrade, OpenTofu shows no changes and the Helm diff shows the Gitea image tag
changing.

Watch the upgrade: before you merge, start the health check in a second terminal, with the
same AWS credentials and region:

```sh
AWS_REGION=us-west-2 scripts/zero-downtime-upgrade-healthcheck.sh
```

Then merge. The merge to `main` runs the apply job, and the pods roll one at a time:

```sh
gh pr merge --squash --delete-branch
gh run watch
```

### What the health check shows

It needs only the AWS CLI, git and curl. It finds the load balancers by their tags, logs in as
the admin, and makes a test repo and a temporary SSH key. Then five loops hit Gitea every 1 to 3
seconds: `/api/healthz`, `git ls-remote` over HTTP and SSH, a push over SSH, and an issue created
through the API. Every 5 seconds it prints each check's last result and its ok/fail count:

```
04:12:20  healthz ok       9/0  https-ls-remote ok       3/0  ssh-ls-remote ok       3/0  ssh-push ok       2/0  api-write ok       3/0
```

The second number is failures and should stay at 0. Leave it running a minute after the
rollout ends, then press Ctrl-C. It prints the totals and the time of any failure, and keeps
every result in `zero-downtime-healthcheck-<time>.log`.

### What happens during the rollout

1. Helm starts one new pod. It gets traffic only after the load balancers see it healthy.
2. One old pod is told to stop. It serves 60 more seconds while traffic moves off it. Then it
   finishes open git operations and exits.
3. The same happens for the second pod. One pod is always serving.
4. On a minor or major upgrade, the first new pod updates the database tables. The old pod
   keeps working meanwhile.

The pods can swap one at a time because they share all data. Repos are on EFS. Users and
issues are in RDS. Sessions and cache are in Valkey. The SSH host key comes from Secrets Manager.

To roll back, don't lower the version. Gitea can't run on tables a newer version changed.
Restore the database with RDS point-in-time recovery instead.

Why each rollout setting is there:
[architecture decisions](adrs/0001-architecture-decisions.md#zero-downtime-rollout-settings).

## Tear down

This removes the whole Gitea stack: the Helm releases (and with them the load balancers), then
the cluster, RDS, Valkey, EFS and the VPC. It takes about 15 minutes.

From your laptop (method 1), with the same AWS credentials and region as the deploy:

```sh
cd bootstrap
AWS_REGION=us-west-2 terragrunt run --all destroy --non-interactive
```

With GitHub Actions (method 2): Actions -> Gitea Deploy -> Run workflow -> `OpenTofu Destroy`.

The bootstrap stays, so the next deploy can reuse it: the state bucket, the KMS key, the IAM
roles, the secrets and the GitHub OIDC provider. Together they cost about $3 a month. The KMS
key has `prevent_destroy`, and the bucket holds the bootstrap's own state, so `state/` can't
destroy itself. To remove the bootstrap too, delete those resources by hand, then schedule the
key for deletion (7 days is the shortest AWS allows):

```sh
aws kms schedule-key-deletion --region us-west-2 --pending-window-in-days 7 \
  --key-id "$(aws kms describe-key --region us-west-2 --key-id alias/gitea-<suffix>-tofu-state --query KeyMetadata.KeyId --output text)"
```

## Demo limitations

The pieces below are kept single to save cost. A Gitea upgrade touches none of them, and each
has a known production fix.

- The database is in one AZ. AWS maintenance or a failure takes it down for a few minutes.
  Multi-AZ (`db_multi_az = true`) cuts that to about 40 seconds. RDS Proxy would turn those
  seconds into slow requests instead of errors.
- Valkey is a single node. If it restarts, users are logged out and queued jobs are lost.
- HTTP only, on the load balancers' own hostnames. A domain would add HTTPS and a real SSH
  clone URL (Gitea's UI shows `git@localhost:...` without one).
