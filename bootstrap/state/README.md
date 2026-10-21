# bootstrap/state

One-time setup for the AWS account your credentials point at (region from `AWS_REGION`,
default us-west-2). A person runs it from a laptop; CI never runs it, because CI logs in with
the roles it creates.

## What it creates

In AWS:

- S3 bucket `gitea-tfstate-<account id>-<region>` for OpenTofu state (versioned, SSE-S3,
  public access blocked, ACLs disabled, TLS only). Terragrunt creates it on
  `--backend-bootstrap`, and this unit adopts it with an `import` block.
- KMS key `alias/gitea-tofu-state` (rotation on, `prevent_destroy`). OpenTofu encrypts the
  state and plan files of the `gitea` unit with it. To reuse a key kept from an earlier build of
  the account, set `EXISTING_STATE_KMS_KEY_ID=<key id>` once; otherwise a new key is created.
- The GitHub OIDC provider and two roles:
  - `github-plan`: ReadOnlyAccess, plus the state lockfile, the state key and reads of the
    `gitea/*` secrets. Only the `sandbox-plan` environment can assume it.
  - `github-apply`: AdministratorAccess. Only the `sandbox-apply` environment can assume it.
- `platform-eks-admin`, the role people assume for `kubectl` (any admin in this account can
  assume it; the cluster gives it admin access).
- Secrets Manager secrets `gitea/db`, `gitea/valkey`, `gitea/admin` and `gitea/metrics` (random
  values) and `gitea/ssh-host-key` (an ed25519 key every Gitea pod serves). All are written with
  write-only arguments, so no value is in state or plan output.

In GitHub, only when `GITHUB_TOKEN` is set (the repository is this clone's `origin` remote):

- Environments `sandbox-plan` (any branch) and `sandbox-apply` (`main` only), each with the
  variable `AWS_ROLE_ARN` set to its role.
- The repository variable `BOOTSTRAPPED=true`. The workflow skips every job until it exists.

## Before you run it

- Admin AWS credentials for the account (`aws sts get-caller-identity`). Set
  `EXPECTED_ACCOUNT_ID` to make OpenTofu refuse any other account.
- For the GitHub side: `gh auth login` as a user with admin rights on the repository. Without
  `GITHUB_TOKEN` the bootstrap leaves GitHub alone.
- `mise install` anywhere in the repo (tool versions are in `.mise.toml`).

## Run

From `bootstrap/`:

```sh
GITHUB_TOKEN=$(gh auth token) terragrunt apply --working-dir state --backend-bootstrap
```

`--backend-bootstrap` creates the state bucket before OpenTofu starts, so this unit's own state
goes there too. You can run it again at any time; it only changes what drifted.

Then start the first deploy (Actions -> Gitea deploy -> Run workflow -> `apply`) and delete any
long-lived IAM user or access key you used for the bootstrap.

## No OpenTofu state encryption for this unit

This unit creates the KMS key that encrypts the other state, so it can't use that key itself.
Its state is protected by S3 server-side encryption only. It holds resource IDs and ARNs, and
no secret values.

## Notes

- Bumping a secret's `version` in `main.tf` writes a new value. The stack uses it on its next
  apply.
- Secrets are deleted without a recovery window, so a rebuild can reuse the names.
- OpenTofu never destroys the state key (`prevent_destroy`). A teardown leaves it in place, and
  the next bootstrap adopts it instead of creating another key.
