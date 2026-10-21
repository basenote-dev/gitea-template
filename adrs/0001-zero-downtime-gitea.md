# ADR 0001: How Gitea upgrades without downtime

Status: accepted, 2026-10-21

## What zero downtime means here

While Gitea moves to a new version, every request keeps working: the web UI, the API, and git
over HTTP and over SSH, for reads and for writes. Nobody gets an error, a dropped clone or a
lost push.

It covers Gitea upgrades (patch, minor and major) and any other change that replaces the pods,
like a config change. It does not cover AWS restarting the database or the cache; that is in
"Known limits" below.

## Why this takes more than one pod

An upgrade replaces the program that is answering requests. With one copy of Gitea, there is a
moment when the old one has stopped and the new one hasn't started, and requests fail. The only
way around that is to have a second copy serving while the first one is replaced.

So Gitea runs as 2 pods. That is the minimum: one pod is always serving while the other is
swapped. Gitea's own HA guide says the same ("at least two application nodes"). A third pod
would add cost and change nothing about upgrades.

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

## What happens during an upgrade

1. Someone changes `gitea_version` in `aws/main.tf` in a pull request. The PR shows the plan;
   merging it starts the deploy.
2. Kubernetes starts one new pod with the new version (`maxSurge: 1`). Both old pods keep
   serving.
3. On a minor or major upgrade, the new pod updates the database tables before Gitea starts
   (see "The database during an upgrade" below). The old pods keep serving while it does.
4. The load balancers (an ALB for web and git over HTTP, an NLB for SSH) send the new pod traffic
   only after it passes their health checks. Kubernetes waits for that too (readiness gates),
   so it doesn't count the pod as ready before users can reach it.
5. Kubernetes tells one old pod to stop. It keeps serving for 60 seconds while the load balancers
   stop sending it new connections, then has up to 5 minutes to finish open clones and pushes.
6. Steps 2 to 5 repeat for the second pod. At no point are both pods down (`maxUnavailable: 0`,
   and a disruption budget that keeps at least 1 pod).

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

## Known limits

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
