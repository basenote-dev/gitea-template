# Requirements

How the assignment maps to this repo. Why each choice was made is in
[architecture decisions](../explanation/architecture-decisions.md).

## Core

| Requirement | Status | How |
| --- | --- | --- |
| Gitea on a cloud provider | Done | AWS, us-west-2 by default |
| Containerized host | Done | EKS Auto Mode cluster, Gitea in 2 pods (official Helm chart, rootless image) |
| PostgreSQL, external and networked | Done | RDS PostgreSQL 17, private subnets, TLS only |
| Reverse proxy | Done | ALB for HTTP (Kubernetes Ingress), NLB for SSH |
| IaC with Terraform and Ansible | Done, with a change | OpenTofu (Terraform-compatible) plus Terragrunt and Helmfile. No Ansible: there are no servers to configure |

## Stretch

| Goal | Status | How |
| --- | --- | --- |
| Zero-downtime updates | Done | Rolling update of 2 pods with shared storage. Three upgrades measured with 0 failed requests (below) |
| Filesystem and data consistency | Done | Repos on EFS, data in RDS, sessions and locks in Valkey, shared keys. Migrations run once, before the new pod serves |
| ADR | Done | [Architecture decisions](../explanation/architecture-decisions.md) |
| Security hardening | Done | See "Security" below |
| Baseline observability | Done | CloudWatch Container Insights, EKS control plane logs, RDS logs. Gitea metrics on, not scraped |
| Production considerations | Documented | See "Before production" below |
| "yoink" in a code comment | Done | `helmfile/helmfile.yaml.gotmpl` |

## Upgrade tests

`scripts/zero-downtime-upgrade-healthcheck.sh` ran from before each merge until after the last
pod was replaced. It checks `/api/healthz` every second, and every 1 to 3 seconds it runs
`git ls-remote` over HTTP and SSH, pushes a commit over SSH, and creates an issue through the
API.

| Upgrade | Checks | Failed |
| --- | --- | --- |
| 1.26.3 to 1.27.3 (minor) | 829 | 0 |
| 1.27.3 to 28.2.0 (major) | 866 | 0 |
| 1.26.3 to 1.26.4 (patch) | 960 | 0 |

A gap shorter than the check interval could fall between two checks.

## Security

Network:

- RDS, Valkey and EFS are in private subnets. Each has its own security group that accepts only
  the cluster.
- RDS rejects connections without TLS (`rds.force_ssl`). Valkey uses TLS and an auth token.
- The ALB drops requests with invalid header fields.
- Who may reach Gitea is one setting, `allowed_cidrs` in `aws/main.tf`.

Data at rest:

- RDS, Valkey and EFS are encrypted.
- OpenTofu state and plan files are encrypted on the client with a KMS key before they reach
  S3. The state bucket is versioned, blocks public access and accepts TLS only.

Secrets:

- Every password and key is random and written write-only, so none is in Git, state or plan
  output.
- External Secrets can read only Gitea's six secrets.

Access:

- No AWS keys are stored in GitHub. CI logs in with OIDC, scoped to this repo and one GitHub
  environment. Plans are read-only, and only `main` can deploy.
- The cluster uses EKS access entries. Creating the cluster doesn't make anyone admin.
- GitHub Actions are pinned to commit SHAs.

Pods:

- The namespace enforces Pod Security `baseline` and warns on `restricted`.
- Gitea runs rootless, as a non-root user, with no privilege escalation, all Linux capabilities
  dropped and the default seccomp profile.
- The EFS access point limits pods to Gitea's folder, as uid and gid 1000.
- Open registration is off. The admin user's password comes from Secrets Manager.

## Observability

| What | Where |
| --- | --- |
| Pod and node metrics, container logs | CloudWatch Container Insights (EKS add-on) |
| Kubernetes API, audit and authenticator logs | CloudWatch, `/aws/eks/<cluster>/cluster` |
| PostgreSQL and upgrade logs | CloudWatch, `/aws/rds/instance/<db>/` |
| Gitea metrics | `/metrics`, behind a token. Nothing scrapes it yet |
| Upgrade health | `scripts/zero-downtime-upgrade-healthcheck.sh` |

Logs are kept 30 days.

## Before production

| Gap in the demo | What production would do |
| --- | --- |
| HTTP only, no domain | A domain, an ACM certificate on the ALB, and a real SSH clone URL |
| RDS in one AZ | Multi-AZ (about 40 seconds of failover instead of minutes), RDS Proxy to absorb failovers |
| One Valkey node | A replica with automatic failover |
| Pods can share a node | Require spreading across nodes and AZs |
| `allowed_cidrs` is open to the internet | Limit it, and add AWS WAF on the ALB |
| Public EKS API endpoint | Private endpoint, or a list of allowed CIDRs |
| CI deploy role is a full admin | Scope it to the services the stack uses |
| Every account admin is cluster admin | A read-only role for most people |
| Nothing scrapes Gitea's metrics | Prometheus and Grafana, with alerts on health checks, database and cache |
| One environment | Separate staging and production accounts, promoted through the same pipeline |
