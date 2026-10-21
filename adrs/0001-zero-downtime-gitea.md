# ADR 0001: How Gitea upgrades without downtime

Status: accepted, 2026-10-21

## What zero downtime means here

While Gitea moves to a new version, every request keeps working: the web UI, the API, and git
over HTTP and over SSH, for reads and for writes. Nobody gets an error, a dropped clone or a
lost push.

It covers Gitea upgrades (patch, minor and major) and any other change that replaces the pods,
like a config change. It does not cover AWS restarting the database or the cache; that is in
"Demo limitations" below.

## Why this takes more than one pod

An upgrade replaces the program that is answering requests. With one copy of Gitea, there is a
moment when the old one has stopped and the new one hasn't started, and requests fail. The only
way around that is to have a second copy serving while the first one is replaced.

So Gitea runs as 2 pods. That is the minimum: one pod is always serving while the other is
swapped. Gitea's own HA guide says the same ("at least two application nodes"). A third pod
would add cost and change nothing about upgrades.

The two pods are identical: same image, same config, no special roles. The load balancers spread
requests across both, so one request can land on pod A and the next on pod B. To a user they are
one Gitea; the second copy exists so one is always left while the other is replaced.

Two pods only work if they behave like one Gitea. Whatever one pod knows, the other must know
too, and a new pod must start with all of it. Gitea keeps five kinds of state, and each one
lives outside the pods:

| State | Where it lives | Why there |
| --- | --- | --- |
| Git repositories, LFS files, attachments, avatars | EFS | Both pods read and write the same files at the same time |
| Users, issues, pull requests, permissions | RDS PostgreSQL | One database both pods share |
| Sessions, cache, background job queues, locks | ElastiCache Valkey | A user logged in on one pod stays logged in on the other; a job runs once, not once per pod |
| SSH host key | Secrets Manager, mounted into both pods | SSH clients see the same server whichever pod answers |
| Search index for issues | RDS (Gitea's database indexer) | Gitea's default file index (bleve) can't be opened by two pods |

Because the pods hold nothing, any pod can be stopped at any time and a new one can take its
place. Gitea's HA guide lists the same requirements:
https://gitea.com/gitea/helm-gitea/raw/tag/v12.7.0/docs/ha-setup.md and
https://docs.gitea.com/enterprise/installation/high-availability/

### Why EFS

Gitea stores every repository as plain git files on disk, not in the database. Both pods need
those files at the same moment: a push can land on one pod and the next clone on the other.
During an upgrade an old and a new pod also run at once.

An EBS disk, the default for Kubernetes on AWS, attaches to one server at a time. With EBS, only
one pod can run, so an upgrade has to stop it before starting the new one (Kubernetes calls this
`Recreate`), which is downtime on every deploy. EFS is a network file system that many servers
mount and write at once (Kubernetes calls this ReadWriteMany). Both pods mount the same EFS
volume and share one copy of every repo.

Side benefits: the repos live outside the cluster, so rebuilding EKS loses nothing, and AWS
Backup copies the volume daily. The cost is speed: EFS is slower than a local disk for very
large repos.

### Why Valkey

Gitea keeps logins, cached pages, background job queues and locks in memory by default. With two
pods, each would have its own: a user logged in through one pod would look logged out on the
other, and both pods would run the same background jobs. Valkey (an open source Redis) is one
shared store for all of it. Gitea's HA guide requires a Redis-compatible store for this.

### Why one shared SSH host key

An SSH server proves who it is with its host key, and SSH clients remember it. If each pod made
its own key, the server's identity would change depending on which pod the load balancer picked,
and SSH would refuse to connect ("REMOTE HOST IDENTIFICATION HAS CHANGED"). We saw exactly that
in testing: the two pods started at the same moment and each made its own key. The key is now
made once, kept in Secrets Manager and mounted into every pod. It also survives cluster rebuilds,
so users' `known_hosts` keep working.

## What we added on top of a plain Gitea install

A plain Gitea install on Kubernetes is one pod on a private disk. Every row below is a change
from that, and each one closes a specific gap.

| Setting | Where | What it does | Without it |
| --- | --- | --- | --- |
| `replicas: 2` | `helmfile/env/sandbox.yaml` | Runs two copies of Gitea | One copy, so replacing it leaves a gap |
| Shared EFS volume (ReadWriteMany) | `aws/main.tf`, `helmfile/charts/gitea-cluster` | Both copies read and write the same repos | Each copy would need its own disk, and an EBS disk can't be shared |
| Valkey for cache, sessions, queues and locks | `aws/main.tf`, `helmfile/charts/gitea-config` | Both copies share logins and background work | A user logged in on one pod looks logged out on the other; jobs run twice |
| Database issue indexer | `helmfile/values/gitea.yaml.gotmpl` | Search works with two copies | Gitea's default index (bleve) can only be opened by one copy |
| One SSH host key from Secrets Manager | `bootstrap/state`, `helmfile/charts/gitea-config` | Both copies show SSH clients the same identity | SSH refuses every other connection |
| `maxSurge: 1` | `helmfile/values/gitea.yaml.gotmpl` | During an upgrade Kubernetes may run one extra pod (3 in total), so it starts the new pod before stopping an old one | Kubernetes could stop an old pod first |
| `maxUnavailable: 0` | same file | Never fewer than 2 ready pods during an upgrade | Kubernetes could drop to 1 ready pod, or none |
| Disruption budget, `minAvailable: 1` | same file | Covers everything that isn't an upgrade: when AWS replaces or empties a node, Kubernetes won't evict a pod if that would leave none running | A node replacement could stop both pods at once |
| Readiness gates | `helmfile/charts/gitea-cluster/templates/namespace.yaml` | A new pod counts as ready only once the ALB and NLB send it traffic | Kubernetes could stop an old pod while the load balancers still can't reach the new one |
| 60 s pause before a pod stops (preStop) | `helmfile/helmfile.yaml.gotmpl` | A stopping pod keeps serving while the load balancers move traffic off it | New connections still arriving get refused (a 15 s pause dropped one SSH connection in testing) |
| 300 s load balancer drain | `helmfile/values/gitea.yaml.gotmpl` | Connections already open to a leaving pod are allowed to finish | Long clones and pushes get cut |
| 300 s Gitea graceful shutdown, 360 s before Kubernetes force-kills | same file | Gitea finishes open requests before it exits | Gitea is killed mid-request |

`maxSurge` and `maxUnavailable` decide how an upgrade swaps pods. The disruption budget is a
separate guard for the times AWS moves pods around on its own, like when Auto Mode replaces a
node.

## What happens during an upgrade

1. Someone changes `gitea_version` in `aws/main.tf` in a pull request. The PR shows the plan;
   merging it starts the deploy.
2. Kubernetes creates a third pod with the new version (`maxSurge: 1` allows one extra pod
   during an upgrade). The two old pods keep serving everything; the new pod gets no traffic
   yet.
3. The new pod starts like every Gitea pod: it updates the database tables if the version needs
   it (see "The database during an upgrade" below), mounts the same EFS volume, loads the same
   SSH host key and connects to RDS and Valkey. All three pods now share the same data.
4. Kubernetes waits for the new pod's readiness probe to pass: Gitea answers and can reach the
   database and cache. (The liveness probe is a different check that only restarts a pod that
   hangs; it doesn't decide traffic.)
5. The load balancer controller registers the new pod with the ALB (web and git over HTTP) and
   the NLB (SSH). They run their own health checks and start sending it users only when those
   pass. The readiness gate makes Kubernetes wait for that too, so the pod doesn't count as
   ready until users can actually reach it.
6. Kubernetes picks one old pod to stop. It may, because 2 ready pods remain
   (`maxUnavailable: 0`). The pod is marked as terminating and the controller starts taking it
   out of the load balancers, which takes about 15 seconds or more. The pod keeps running
   normally for 60 seconds (the preStop pause), so anything that still reaches it is served.
7. After those 60 seconds Gitea is told to shut down. It stops taking new work but finishes what
   is in flight (page loads, clones, pushes) for up to 5 minutes.
8. Meanwhile the load balancers drain that pod: they send it nothing new but keep its open
   connections for up to 5 minutes instead of cutting them. A clone or push that started on the
   old pod finishes on the old pod. Then the pod exits.
9. Steps 2 to 8 repeat for the second old pod.

Every connection is covered. One that arrives before the load balancers stop routing to an old
pod is served by it, because the pod keeps running through the 60-second pause. One already in
progress when shutdown starts is finished by Gitea while the load balancer holds it open. One
that arrives later goes to the two ready pods. The only gap: a single clone or push longer than
5 minutes would be cut when the old pod exits; raising the drain and shutdown limits closes it.

From merge to finished rollout takes about 3.5 minutes.

### The database during an upgrade

A new Gitea version can change the database tables. The Gitea Helm chart handles that itself:
every Gitea pod has an init container, `configure-gitea`, that runs `gitea migrate` before Gitea
starts (`templates/gitea/init.yaml` in the chart). There is no separate job to run.

- Only the first new pod changes the tables. With `maxSurge: 1` one new pod starts at a time, so
  two pods never migrate at once; the second new pod's `gitea migrate` finds nothing to do.
- Nothing can kill the pod halfway through. Kubernetes health probes only watch the main Gitea
  container, not init containers, so a slow migration is left to finish.
- A failed migration doesn't take Gitea down. The init container exits with an error and the new
  pod never becomes ready. With `maxUnavailable: 0`, Kubernetes never stops an old pod until a
  new one is ready, so both old pods keep serving. The deploy fails in CI and nobody using Gitea
  notices.
- A version set lower by mistake ends the same way: the new pod refuses to start on tables a
  newer version changed, and the old pods keep serving.
- The old pods keep working on the updated tables until they are replaced. That held in both
  upgrade tests, 1.26 to 1.27 and 1.27 to 28.

The database itself is never restarted or switched during an upgrade.

The 60-second pause is there because the load balancers need time to notice a pod is leaving:
the controller starts removing it about 15 seconds after Kubernetes asks the pod to stop, and the
NLB takes a while longer. A 15-second pause dropped one SSH connection in testing.

To roll back, don't lower the version: Gitea can't run on tables that a newer version changed.
Restore the database with RDS point-in-time recovery to a minute before the upgrade.

## How we know it works

`scripts/zero-downtime-upgrade-healthcheck.sh` runs on a laptop from before the merge until 90
seconds after the last pod is replaced. Through the public load balancers, it checks
`/api/healthz` every second, and every 3 seconds runs a `git ls-remote` over HTTP and over SSH,
pushes a commit over SSH and creates an issue through the API. Any error, non-200 response or
timeout counts as a failure.

| Upgrade | PR | Checks | Failed | Merge to rollout done |
| --- | --- | --- | --- | --- |
| Minor, 1.26.3 to 1.27.3 | [gitea-deployment#9](https://github.com/basenote-dev/gitea-deployment/pull/9) | 793 | 0 | 3 min 16 s |
| Major, 1.27.3 to 28.2.0 | [gitea-deployment#10](https://github.com/basenote-dev/gitea-deployment/pull/10) | 834 | 0 | 3 min 37 s |

A real repository (spf13/cobra, 1,106 commits) cloned the same over HTTP and SSH before and
after both upgrades. Across all test runs, the number of issues stored matched the number of
successful API writes exactly.

The check samples every 1 to 3 seconds, so a gap shorter than that could pass between two
checks.

## Demo limitations

This demo is about one thing: upgrading Gitea without downtime. Everything Gitea needs for
that runs in two copies or lives outside the pods. The pieces below are kept single and simple
to save cost; none of them is touched by a Gitea upgrade, and each has a known fix for
production.

- The database runs in one AZ. When AWS patches it or the hardware fails, it is offline for a
  few minutes and Gitea fails requests until it is back. Upgrades never touch it. Multi-AZ RDS
  cuts that to about 40 seconds (measured with a forced failover), and RDS Proxy in front would
  turn those seconds into slow requests instead of errors. Both are left out to keep the sandbox
  cheap and simple.
- Valkey is a single node. If it restarts, users are logged out and queued jobs are lost.
- The two pods prefer different AZs but can share one node. Upgrades are unaffected; losing that
  node would cause a short outage.
- HTTP only, on the load balancers' own hostnames. Without a domain, Gitea's UI shows
  `git@localhost:...` as the SSH clone URL.

## Alternatives we didn't take

- One pod on an EBS disk with `Recreate`: the simplest setup, and the usual one, but every
  deploy is an outage.
- A StatefulSet with a disk per pod: each pod would have its own copy of the repos, and they
  would drift apart.
- Gitea's built-in Postgres and Valkey charts: they would run inside the cluster, so a cluster
  rebuild would lose the data, and they'd need their own HA setup.
