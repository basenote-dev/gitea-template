# ADR 0002: Everything we built ourselves

Status: accepted, 2026-10-21

Most of this repo is off the shelf. That means the modules in `modules/`, the official Gitea
and External Secrets charts, EKS Auto Mode, and stock GitHub Actions. This page lists every
piece we wrote or changed on top.

"Needed for zero downtime" means an upgrade would drop requests without it.

## In the repo today

### Bootstrap (`bootstrap/state/`)

| Piece | What it does | Why | Needed for zero downtime | Could drop |
| --- | --- | --- | --- | --- |
| State bucket adopted with an `import` block | Terragrunt creates the empty bucket, then this unit manages it (versioning, encryption, TLS-only) | The bucket must exist before any state can be written | No | No |
| State KMS key, `prevent_destroy`, optional `EXISTING_STATE_KMS_KEY_ID` import | Encrypts the gitea unit's state and plan files; never destroyed by OpenTofu | Secrets and endpoints in state are ciphertext; a teardown doesn't destroy the key | No | The import variable, if keys are never reused |
| GitHub OIDC roles with a hand-written trust policy | `github-plan` (read-only, any branch) and `github-apply` (admin, `main` only), each trusting one environment of this repo by its numeric IDs | The module's built-in option checks `aud` loosely and can race the provider | No | No |
| `USE_EXISTING_GITHUB_OIDC_PROVIDER` switch | Roles trust the account's existing GitHub OIDC provider instead of creating one | AWS allows one per account, and a second account we tested already had one from another project | No | No |
| `platform-eks-admin` role | The role people assume for `kubectl` | The cluster's access entries never reference anyone's SSO role | No | No |
| Secrets with random, write-only values (`gitea/db`, `valkey`, `admin`, `metrics`) | Generated once, never in state or plan output | Passwords stay out of Git and state | No | No |
| `gitea/ssh-host-key` (ephemeral ed25519 key) | One SSH host key for every pod | Two pods with different keys make SSH refuse every other connection (seen in testing) | Yes | No |
| `gitea/app-ini-keys` (Gitea's four signing keys) | Same SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET, LFS_JWT_SECRET for every pod | Each pod generates its own on a fresh install (seen in testing) | Yes | No |
| GitHub environments, `AWS_ROLE_ARN` variables, `BOOTSTRAPPED` variable | Tell the workflow which role to assume; `BOOTSTRAPPED` turns the workflow on | No AWS keys in GitHub; a repo that hasn't been bootstrapped runs nothing | No | The environments could become trust on branch and PR instead (discussed, not done) |

### Terragrunt (`bootstrap/root.hcl`, `bootstrap/gitea/terragrunt.hcl`)

| Piece | What it does | Why | Needed for zero downtime | Could drop |
| --- | --- | --- | --- | --- |
| Generated backend, AWS provider and state encryption | Written into each unit at run time | No unit repeats them | No | No |
| Repo name read from `git remote get-url origin` | Tags resources with the repo and builds the OIDC trust | A fork trusts itself without edits | No | Could be a typed-in value instead |
| `EXPECTED_ACCOUNT_ID` guard | When set, OpenTofu refuses any other account | Protects against running in the wrong account | No | Yes |
| Hooks: kubeconfig, `helmfile diff` after plan, `helmfile apply` after apply, `helmfile destroy` before destroy | One Terragrunt command covers AWS and the cluster | No separate deploy script | No | No |
| Hooks: wait for the load balancers, print the URL and SSH host | Shows where Gitea is at the end of an apply | Convenience | No | Yes |
| `cluster_exists` check (`aws eks list-clusters`) | Skips Helm on a plan or destroy when there is no cluster yet | A fresh account has nothing to diff or uninstall | No | No |

### AWS stack (`aws/main.tf`)

| Piece | What it does | Why | Needed for zero downtime | Could drop |
| --- | --- | --- | --- | --- |
| Valkey as plain resources, not the module | ElastiCache with `auth_token_wo` | The module only has `auth_token`, which stores the token in state | Valkey itself is; the plain resource is a detail | No |
| CloudWatch add-on as a plain resource, plus its log groups | Container Insights, with log groups OpenTofu owns | Otherwise the agent makes them and nothing deletes them | No | Yes, if you don't want Container Insights |
| External Secrets IAM policy written by hand | Reads exactly the six `gitea/*` secrets | The module's policy can list every secret and use every key | No | No |
| One security group per data store | PostgreSQL, Valkey and NFS open only to the cluster | The RDS module has no security group | No | No |
| `rds.force_ssl` with `apply_method = "pending-reboot"` | TLS-only database | Without the explicit apply method, every plan shows a change | No | No |
| EFS access point pinned to uid/gid 1000 at `/gitea` | Pods see only Gitea's folder, as the Gitea user | Least privilege on the shared volume | EFS itself is | No |

### Helmfile and charts (`helmfile/`)

| Piece | What it does | Why | Needed for zero downtime | Could drop |
| --- | --- | --- | --- | --- |
| `values/tofu-outputs.yaml.gotmpl` runs `terragrunt output` | Helmfile reads endpoints and secret names straight from OpenTofu | No copied values to keep in sync | No | No |
| Version check on `gitea_version` | Refuses anything that isn't `x.y.z` | A typo fails the plan instead of the deploy | No | Yes |
| `charts/gitea-cluster` (our chart) | Namespace with Pod Security labels and the readiness gate label; the EFS PersistentVolume; the ALB IngressClass | Cluster-wide objects the Gitea chart doesn't create | Yes (readiness gates, EFS) | No |
| `charts/gitea-config` (our chart) | SecretStore and ExternalSecrets (admin, app.ini sections, SSH key), the EFS claim | Gitea's secrets and storage, wired to AWS | Yes (shared keys, EFS claim) | No |
| Gitea chart values | Every difference from the stock chart is in ADR 0001, "Where we differ from the stock Gitea chart" | | Most of them | See ADR 0001 |
| `strategicMergePatches`: `preStop: sleep 60` | Adds the 60 s pause before a pod stops | The Gitea chart has no setting for it | Yes | No |
| `strategicMergePatches`: no per-pod `app.ini` mount on `init-directories` | The first init step creates `/data/gitea/conf` on EFS itself | With the mount there, two pods on a fresh volume raced to create that folder (seen) | Fresh installs only | No |
| `initPreScript` creating Gitea's folders, OAuth2 `HS256` | Gitea never creates a folder or key file on the shared volume at first start | Two pods starting together raced on `/data/home` and `/data/jwt` (seen) | Fresh installs only | No |

### Pipeline and tooling

| Piece | What it does | Why | Needed for zero downtime | Could drop |
| --- | --- | --- | --- | --- |
| `BOOTSTRAPPED` check on every job | The workflow runs nothing until the bootstrap has run | Pushing to a fresh clone doesn't start a deploy that can't log in | No | Yes, at the cost of one failed run per new repo |
| Run names built from the PR or commit | Readable Actions list | Every run used to say "terragrunt" | No | Yes |
| `.mise.toml` helm-diff fix (`rename_exe`, `bin_path`, `HELM_PLUGINS`) | Makes the pinned helm-diff plugin work and keeps it off PATH | mise renames the binary Helm needs, and it shadowed `diff` | No | No, while helm-diff comes from mise |
| `scripts/zero-downtime-upgrade-healthcheck.sh` | Measures failed requests during an upgrade | The proof that upgrades drop nothing | It proves it | No |
| GitHub repo settings: merge commits titled after the PR, outside contributors' runs need approval | Readable history; no surprise runs from forks | | No | Yes |
