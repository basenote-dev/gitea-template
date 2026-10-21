# bootstrap/state

One-time setup that lets GitHub Actions deploy everything else in the sandbox account
(the account of your AWS credentials; region from `AWS_REGION`, default us-west-2) with no
stored AWS keys. A human runs it once; it is not part of CI.

## What this creates

AWS:

- Terraform state: S3 bucket `gitea-tfstate-<account_id>-us-west-2` (versioned, SSE-S3, public
  access blocked, ACLs disabled, TLS only). Terragrunt creates it; this root adopts it with an
  `import` block.
- State encryption key: KMS key `alias/gitea-tofu-state` (rotation on, `prevent_destroy`).
  OpenTofu encrypts the state and plan files of every other root with it. A key kept from an
  earlier build of the account can be adopted once with `EXISTING_STATE_KMS_KEY_ID=<key id>`
  (`import` blocks); otherwise a new key is created.
- GitHub OIDC: the IAM OIDC provider for `token.actions.githubusercontent.com` and two roles:
  - `github-plan`: ReadOnlyAccess, plus the state lockfile, the state key, `gitea/*` secret reads. Trusted only by the `sandbox-plan` environment.
  - `github-apply`: AdministratorAccess. Trusted only by the `sandbox-apply` environment.
- Cluster admin role `platform-eks-admin` for humans (trust: this account; the account stack
  grants it EKS cluster admin).
- Secrets Manager secrets `gitea/db`, `gitea/valkey`, `gitea/admin`, `gitea/metrics` with random
  values. The values are write-only: they are not in state or plan output.

GitHub (only with `GITHUB_TOKEN` set; the repository is this clone's `origin` remote):

- Environments `sandbox-plan` (any branch) and `sandbox-apply` (deployment branch policy: `main`
  only), each with variable `AWS_ROLE_ARN` set to its role.

## Prerequisites

- Admin AWS credentials for the target account in your shell (`aws sts get-caller-identity`).
  Set `EXPECTED_ACCOUNT_ID` to make OpenTofu refuse any other account.
- For the GitHub side only: `gh auth login` as a user with admin on the repository
  (environments and variables need it). Without `GITHUB_TOKEN` bootstrap skips GitHub.
- `mise install` anywhere in the repo (pinned tools in `.mise.toml`).

## Run

From `bootstrap/`:

```sh
GITHUB_TOKEN=$(gh auth token) mise exec -- \
  terragrunt apply --working-dir state --backend-bootstrap
```

`--backend-bootstrap` creates the state bucket before OpenTofu starts, so this root's state goes
there too. Running the command again is safe: it only changes what drifted.

## Next

1. Check the outputs: `github_plan_role_arn`, `github_apply_role_arn`, `secret_names`.
2. Open a pull request: the plan workflow assumes `github-plan` through `sandbox-plan`.
3. Merge to `main`: the apply workflow assumes `github-apply` through `sandbox-apply` and builds
   the Gitea stack and Helm releases.
4. Delete any long-lived IAM user or access key used for this run.

## Exception: no OpenTofu state encryption here

Every other root has its state and plan files encrypted by OpenTofu with the KMS key above
(root.hcl). This root creates or adopts that key, so it can't use it: its state is only S3
server-side encrypted. It holds no secret values (passwords are write-only), only resource IDs
and ARNs.

## Notes

- Bumping a secret's `version` in `main.tf` writes a new random value. The stack picks it up on
  its next apply.
- Sandbox settings: secrets are deleted without a recovery window.
- The state key is never destroyed by OpenTofu (`prevent_destroy`). Account teardowns leave it
  in place so the next bootstrap adopts it instead of creating another key.
