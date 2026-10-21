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

We tested both ways EBS could be shared on this cluster (2026-10-21):

- A volume requested as shared (ReadWriteMany): AWS refuses to create it. `ProvisioningFailed:
  rpc error: code = InvalidArgument desc = Volume capabilities not supported`.
- A normal EBS volume used by two pods on two nodes: the first pod runs, the second never starts.
  `FailedAttachVolume: Volume is already used by pod(s) two-pods-rwo-...`.

ReadWriteOnce means one node, not one pod, so two pods on the same node can share an EBS volume,
but then that one node is a single point of failure. EBS io1/io2 Multi-Attach only works inside
one AZ and as a raw block device, which needs a cluster filesystem on top. EBS volumes also live
in one AZ, so a pod in another AZ can't use them at all. Gitea's HA guide asks for "a RWX
file-system which can be shared among the deployment-based replica pods"; on AWS that is EFS
(managed NFS across AZs, no servers to run) or FSx for NetApp ONTAP (faster, more expensive), or
an NFS or Ceph cluster you run yourself.

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
| A per-pod `app.ini` (emptyDir over `/data/gitea/conf`) | `helmfile/values/gitea.yaml.gotmpl` | Each pod builds its own config file at start | Both pods rewrite one shared file on EFS at once; a pod can read it half-written and start in install mode (seen on a fresh deploy) |
| Gitea's signing keys from Secrets Manager (`gitea/app-ini-keys`) | `bootstrap/state`, `helmfile/charts/gitea-config` | Both pods use the same SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET and LFS_JWT_SECRET | Each pod generates its own keys on a fresh install, so cookies and tokens signed by one pod fail on the other |
| HTTP readiness probe on `/api/v1/version` | `helmfile/values/gitea.yaml.gotmpl` | A pod is ready only when Gitea serves its API | The chart's TCP probe passes for a pod stuck in install mode, so it keeps getting traffic |
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

## What happens during an upgrade, phase by phase

Pods A and B run the old version; C and D are the new ones. "Endpoints" is the list of pods the
Kubernetes Service sends to; the ALB and NLB keep their own target lists, managed by the EKS
Auto Mode load balancer controller. Every pod, in every phase, mounts the same EFS volume at
`/data` read-write and has its own `app.ini` on a per-pod volume.

**Phase 0, steady state.** A and B are Running and Ready. Both are in the Service endpoints and
are healthy targets in the ALB (HTTP, port 3000, checked on `/api/healthz` every 15 s) and the
NLB (SSH, port 2222, TCP check every 10 s). Both serve web, API and git over HTTP and SSH with
the same SSH host key.

**Phase 1, merge.** The PR's `gitea_version` change reaches the cluster as a new image tag in the
Deployment. Kubernetes creates C (`maxSurge: 1`: 3 pods is allowed during an upgrade). A and B
keep serving everything; nothing about them changes.

**Phase 2, C initializes.** C's init containers run in order, before Gitea itself:
`init-directories` (folders on `/data`), `init-app-ini` (writes C's own `app.ini` from the
values and secrets) and `configure-gitea` (`gitea migrate`, then the admin user). On a minor or
major upgrade, `gitea migrate` updates the database tables here; A and B keep working on the
updated tables. C has no traffic: it isn't Ready, so it isn't in the endpoints, and the load
balancers haven't marked it healthy.

**Phase 3, C starts serving, privately.** Gitea starts in C, listening on 3000 (HTTP) and 2222
(SSH) with the shared host key. The controller has registered C's IP in the ALB and NLB target
groups; their health checks run against it. Kubernetes' readiness probe (`GET /api/v1/version`
every 10 s) passes. C is still not Ready, because of its two readiness gates, one per target
group, which only turn true once the ALB check (2 passes, about 30 s) and the NLB check (3
passes, about 30 s) succeed. The liveness probe (TCP, starting after 200 s) only restarts a
hung pod and plays no part in traffic.

**Phase 4, C is Ready.** Both gates are true, so C is Ready: it joins the Service endpoints and
the load balancers send it new connections alongside A and B. Three pods serve.

**Phase 5, A is told to stop.** With C Ready, Kubernetes may remove an old pod and still have 2
Ready (`maxUnavailable: 0`). A is marked Terminating: it leaves the Service endpoints at once,
and the controller starts deregistering it from the ALB and NLB (about 15 s or more to start).
A deregistered target is "draining": it gets no new connections, but its open connections are
kept for up to 300 s. Meanwhile A runs its preStop step, a 60 s pause, during which Gitea keeps
running normally, so any connection that still reaches A in that window is served.

**Phase 6, A shuts down.** After 60 s, Kubernetes sends Gitea in A the stop signal. Gitea stops
accepting new work and finishes what is open (page loads, clones, pushes, SSH sessions) for up to
300 s (`GRACEFUL_HAMMER_TIME`), then exits. Kubernetes force-kills only after 360 s
(`terminationGracePeriodSeconds`, counted from phase 5), which covers the 60 s pause plus the
300 s of shutdown. The load balancers' 300 s drain keeps those connections open on their side for
the same time.

**Phase 7, B is replaced.** Kubernetes creates D and repeats phases 2 to 6 with B. When D is
Ready and B has exited, C and D run the new version and the upgrade is done. At no point did
fewer than 2 pods serve.

Every connection is covered. One that reaches an old pod before the load balancers stop routing
to it is served, because the pod keeps running through the 60 s pause. One already open when
shutdown starts is finished by Gitea while the load balancer holds it. One that arrives later
goes to the Ready pods. The gap: a single clone or push longer than 5 minutes is cut when its pod
exits; raising the drain and shutdown limits closes it.

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

## Where we differ from the stock Gitea chart

We use the official chart (`gitea-charts/gitea` 12.7.0) unchanged and set values for it in
`helmfile/values/gitea.yaml.gotmpl`, plus one patch Helmfile applies after rendering. Everything
else in `helmfile/` is our own: two small charts (`gitea-cluster`, `gitea-config`) and External
Secrets.

| Setting | Stock chart | Ours | Why |
| --- | --- | --- | --- |
| `replicaCount` | 1 | 2 (`helmfile/env/sandbox.yaml`) | One pod always serves while the other is replaced |
| `strategy.rollingUpdate.maxSurge` | 100% | 1 | Add one new pod at a time |
| `strategy.rollingUpdate.maxUnavailable` | 0 | 0 (set explicitly) | Never fewer Ready pods than `replicaCount` |
| `podDisruptionBudget` | none | `minAvailable: 1` | Node replacements can't evict both pods at once |
| `topologySpreadConstraints` | none | prefer different AZs | Losing one AZ usually leaves a pod |
| `persistence` | creates a 10 Gi ReadWriteOnce claim | our ReadWriteMany EFS claim (`create: false`) | Both pods share the repos |
| `extraVolumes`, `extraInitVolumeMounts`, `extraContainerVolumeMounts` | none | SSH host key secret; per-pod emptyDir over `/data/gitea/conf` | Shared SSH identity; no shared `app.ini` |
| `gitea.readinessProbe` | TCP on the HTTP port | `GET /api/v1/version` | Catches a pod that serves but isn't working |
| `deployment.terminationGracePeriodSeconds` | 60 | 360 | Room for the 60 s pause and 300 s graceful shutdown |
| `service.ssh` | ClusterIP | LoadBalancer on the Auto Mode NLB, 300 s drain | SSH from outside, finished on a leaving pod |
| `service.http` | ClusterIP | ClusterIP (unchanged), reached through the Ingress | |
| `ingress` | off | on, Auto Mode ALB, `/api/healthz` check, 3 failures to mark unhealthy, 300 s drain | Web and git over HTTP from outside |
| `postgresql-ha` | on | off; RDS PostgreSQL | Data outside the cluster |
| `valkey-cluster` | on | off; ElastiCache Valkey | Same |
| `test` | on | off | No chart test pod |
| `podSecurityContext`, `containerSecurityContext` | empty | non-root uid 1000, no privilege escalation, all capabilities dropped | Hardening |
| `resources` | none | 250m CPU and 512 Mi requested, 1 Gi memory limit | Predictable scheduling |
| `image.tag` | the chart's app version (1.27.0 for 12.7.0) | `gitea_version` from `aws/main.tf` (registry, rootless and `IfNotPresent` stay as stock) | The version is chosen in one place, by PR |
| `gitea.admin` | username and a fixed password written in the chart's values | from the `gitea-admin` Secret (External Secrets, random password), kept in sync | No password in Git, and none shared with every other install |
| `gitea.additionalConfigSources` | none | `gitea-app-ini-secrets` (database password, Valkey URLs, metrics token, the four signing keys) | Secrets stay out of Git and out of state |
| `gitea.config` | defaults | database on RDS with TLS; cache, session, queue and global lock on Valkey; issue indexer `db`, repo indexer off; built-in SSH server on 2222 with the shared host key; `PUBLIC_URL_DETECTION: auto`; registration off; 300 s graceful shutdown | Two pods share all state; no domain |
| Pod lifecycle | no preStop | `preStop: sleep 60`, added by a Helmfile `strategicMergePatches` (the chart has no value for it) | Load balancers stop routing before Gitea stops |

Outside the chart, one namespace label enables Auto Mode's readiness gates
(`eks.amazonaws.com/pod-readiness-gate-inject: enabled`, in `charts/gitea-cluster`).

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
