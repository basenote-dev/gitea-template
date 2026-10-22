# Architecture decisions

Why the stack is built the way it is. Each section is one decision: what we needed, what we
chose, and what we turned down. For what exists and where, see the
[reference docs](../reference/).

## Run Gitea on EKS Auto Mode

The assignment asks for a containerized host. A single EC2 instance running Docker would meet
that, but upgrading it means stopping the one container, which rules out zero-downtime
upgrades. That needs at least two copies of Gitea and something that replaces them one at a
time while load balancers move traffic. Kubernetes does both.

Auto Mode is the EKS option where AWS runs the nodes, the load balancer controller and the
storage driver for block volumes. We don't patch or size nodes. The cluster asks for capacity
when pods need it.

## Two pods, with no state inside them

Gitea runs as 2 identical pods, and an upgrade replaces them one at a time. With one pod there
is always a gap while it restarts. A third pod would add cost without making upgrades any
safer.

Swapping pods one at a time only works if any pod can serve any request. So nothing that
matters lives inside a pod:

| State | Where | Why there |
| --- | --- | --- |
| Git repos, LFS files, attachments | EFS | Both pods need the same files at the same time |
| Users, issues, pull requests | RDS PostgreSQL | One database both pods use |
| Sessions, cache, job queues, locks | ElastiCache Valkey | Gitea keeps these in memory by default, so each pod would have its own and users would look logged out on the other one |
| Issue search index | RDS (Gitea's `db` indexer) | The default index (bleve) is a file that only one process can open |
| SSH host key, signing keys | Secrets Manager | Generated per pod, they differ, and SSH and logins fail on the other pod |

## EFS for the repos, not EBS, a hostPath or a StatefulSet

Gitea stores repos as plain git directories on disk, and both pods write to them: a push can
land on one pod and the next clone on the other. That needs a volume many nodes can mount at
once (ReadWriteMany).

- An EBS volume attaches to one node. We tested both ways it could work on this cluster. A
  shared EBS volume was refused (`ProvisioningFailed: Volume capabilities not supported`), and
  one volume for two pods on two nodes left the second pod stuck (`FailedAttachVolume: Volume
  is already used`). Keeping both pods on one node would make that node a single point of
  failure.
- EBS Multi-Attach works only inside one AZ, as a raw block device, with a cluster filesystem
  on top. That's more to run than the problem is worth.
- A StatefulSet gives each pod its own volume. Each pod would then have its own copy of every
  repo, and the copies would drift apart.
- A hostPath volume ties the data to one node and is lost with it.

EFS is a managed NFS file system that every node in the VPC can mount. Gitea's own HA guide
asks for a ReadWriteMany file system, and on AWS that means EFS, FSx for NetApp ONTAP, or NFS
you run yourself. EFS also keeps the repos outside the cluster, and AWS Backup copies them
daily. The cost is speed: EFS is slower than a local disk for very large repos.

## PostgreSQL on RDS, not in the cluster

The assignment prefers an external, networked database. RDS gives backups, point-in-time
recovery and patching without running Postgres ourselves, and the data survives if the cluster
is rebuilt. The Gitea chart can install Postgres and Valkey inside the cluster, but then the
data lives and dies with the cluster.

## ALB and NLB as the reverse proxy

The assignment asks for a reverse proxy. The ALB is one: it ends client connections, checks pod
health on `/api/healthz`, and spreads HTTP across the pods. It's also where HTTPS would
terminate once there's a domain. Git over SSH isn't HTTP, so it goes through an NLB instead.
Both are created by EKS Auto Mode from a Kubernetes Ingress and Service, so they follow the
pods during a rollout without anyone editing their config.

## OpenTofu, Terragrunt and Helmfile, not Ansible

The assignment names Terraform and Ansible. We use OpenTofu, the open-source fork of Terraform
that reads the same code, because it can encrypt state and plan files on the client. The state
holds endpoints and resource details, so it's encrypted with a KMS key before it reaches S3.

We left Ansible out because there's nothing for it to configure. Ansible's job is setting up
servers over SSH: packages, files, services. Here AWS runs the nodes, and everything on them is
a container whose config is in Helm values. Adding Ansible would mean a second way to configure
the same things.

- OpenTofu creates everything in AWS (`aws/`).
- Helmfile installs everything inside the cluster (`helmfile/`).
- Terragrunt ties them together: it sets up the state backend, runs OpenTofu in order, and runs
  Helmfile from hooks, so one command deploys the whole stack.

## Zero-downtime rollout settings

Every setting below closes one way a request could fail during an upgrade.

| Setting | What would fail without it |
| --- | --- |
| `maxSurge: 1`, `maxUnavailable: 0` | An old pod could stop before its replacement is ready |
| Readiness probe on `GET /api/v1/version` | The stock TCP check passes on a pod whose Gitea is broken |
| Readiness gates | A pod could count as ready before the load balancers send it traffic, so the next old pod stops too early |
| `preStop: sleep 60` | A stopping pod refuses new connections while load balancers still route to it (a 15-second pause still dropped one) |
| 300 s graceful shutdown, 300 s load balancer drain, 360 s grace period | Long clones and pushes are cut when the pod exits |
| Disruption budget `minAvailable: 1` | A node replacement could take both pods at once |

A database migration runs in the first new pod's init container before Gitea starts. The old
pods keep working on the migrated tables. If the migration fails, the new pod never becomes
ready and the old pods keep serving. Rolling back means restoring the database to before the
upgrade with RDS point-in-time recovery, because Gitea won't start on tables a newer version
changed.

## Fixes for a brand-new install

An upgrade starts one pod at a time. A brand-new install starts both at the same second on an
empty volume, and that caused races we fixed:

- Each pod gets its own `app.ini`. With one shared file, a pod read it half written.
- Gitea's folders are created before Gitea starts, so two pods never race to create them.
- The SSH host key and Gitea's signing keys are generated once by the bootstrap and shared,
  where Gitea would generate a set per pod.
- OAuth2 signs with the shared `JWT_SECRET`, so there's no key file to race on.

## No stored AWS keys

GitHub Actions logs in to AWS with OIDC. Each job trades a short-lived GitHub token for role
credentials that last about an hour. The role's trust policy accepts only this repo, by its
numeric IDs, and only the job's GitHub environment. Plans run as a read-only role from any
branch. Deploys run as the admin role, and only `main` can use that environment.

People reach the cluster through one shared role, `platform-eks-admin`, so no one's personal or
SSO role is written into the cluster's access list.

## Secrets that never appear in state

The bootstrap generates every password and key as an ephemeral value and writes it to Secrets
Manager with write-only arguments. RDS and Valkey read theirs the same way. External Secrets
copies them into the cluster at run time. No secret value is in Git, in OpenTofu state, or in
plan output.

## A random suffix on every name

Some AWS names stay taken after a teardown: a KMS alias while its key waits out the 7-day
minimum before deletion, or roles and log groups that a cleanup missed. A rebuild with fixed
names failed with `AlreadyExists`. The bootstrap picks a random suffix once, keeps it in state,
and every name starts with `gitea-<suffix>`. The state bucket keeps a fixed name, because
Terragrunt needs it before any state exists.

## Observability kept to AWS's own tools

The baseline is CloudWatch: Container Insights for pod and node metrics and container logs, the
EKS control plane's API and audit logs, and the RDS logs. Gitea's Prometheus endpoint is on,
behind a token, but nothing scrapes it yet. We built a Prometheus and Grafana setup with
Gitea-specific alerts in a local cluster. We left it out of this repo, because every piece we
automated for high availability had brought its own surprises, and monitoring would have added
more for a demo.

## Kept small to save cost

The demo is about upgrades without downtime, so the parts an upgrade never touches are single:
one RDS instance in one AZ, one Valkey node, one NAT gateway, and no domain. The
[requirements reference](../reference/requirements.md) lists what each would take for
production.
