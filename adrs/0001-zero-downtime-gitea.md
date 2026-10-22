# ADR 0001: How Gitea upgrades without downtime

Status: accepted, 2026-10-21

## What zero downtime means here

During a Gitea upgrade, every request keeps working: the web UI, the API, and git over HTTP and
SSH, for reads and writes. No request fails and no clone or push is cut off.

This covers Gitea upgrades and anything else that replaces the pods. It doesn't cover AWS
restarting the database or cache; see "Demo limitations".

## Why two pods

An upgrade replaces the running program. With one copy, there's a gap between the old one
stopping and the new one starting. So Gitea runs as 2 pods: one serves while the other is
replaced. That's the minimum, and Gitea's HA guide says the same. A third pod would add cost
without making upgrades any safer.

The two pods are identical. Same image, same config, no special roles. The load balancers send
each request to either one.

That only works if the pods hold no state of their own. Everything lives outside them:

| State | Where | Why |
| --- | --- | --- |
| Repos, LFS files, attachments, avatars | EFS | Both pods read and write the same files |
| Users, issues, pull requests | RDS PostgreSQL | One shared database |
| Sessions, cache, job queues, locks | ElastiCache Valkey | Logins work on both pods; jobs run once |
| SSH host key | Secrets Manager | SSH sees one server, whichever pod answers |
| Issue search index | RDS (database indexer) | The default index (bleve) can't be shared |

Gitea's HA guide lists the same needs:
https://gitea.com/gitea/helm-gitea/raw/tag/v12.7.0/docs/ha-setup.md and
https://docs.gitea.com/enterprise/installation/high-availability/

### Why EFS

Gitea keeps repos as plain git files on disk. Both pods need them at once: a push can land on one
pod and the next clone on the other.

An EBS disk attaches to one node at a time. With EBS you get one pod, and every upgrade has to
stop it first. EFS is a network disk that many nodes mount at once.

We tested EBS on this cluster:

- A shared EBS volume: AWS refuses. `ProvisioningFailed: ... Volume capabilities not supported`.
- One EBS volume, two pods on two nodes: the second pod never starts. `FailedAttachVolume: Volume
  is already used by pod(s) ...`.

Two pods on one node could share EBS, but then that node is a single point of failure. EBS
Multi-Attach only works in one AZ, as a raw block device, with a cluster filesystem on top. The
HA guide asks for "a RWX file-system". On AWS that's EFS, FSx for NetApp ONTAP, or NFS or Ceph
you run yourself.

EFS also keeps the repos outside the cluster, and AWS Backup copies them daily. The downside is
speed: EFS is slower than a local disk for very large repos.

### Why Valkey

By default Gitea keeps logins, cache, job queues and locks in memory. With two pods, each has its
own. A user logged in on one pod looks logged out on the other, and both pods run the same jobs.
Valkey is one shared store for all of it.

### Why one shared SSH host key

An SSH server proves who it is with its host key, and clients remember it. If each pod had its
own, the server would look different depending on which pod answered, and SSH would refuse to
connect. We saw that in testing. Now one key is made once, kept in Secrets Manager and mounted
into every pod. It also survives rebuilds, so `known_hosts` keeps working.

## What we added to a plain Gitea install

A plain install is one pod on a private disk. Each row is a change from that.

| Setting | Where | What it does | Without it |
| --- | --- | --- | --- |
| `replicas: 2` | `helmfile/env/sandbox.yaml` | Two copies of Gitea | A gap during every upgrade |
| Shared EFS volume | `aws/main.tf`, `helmfile/charts/gitea-cluster` | Both pods share the repos | EBS can't be shared |
| Valkey | `aws/main.tf`, `helmfile/charts/gitea-config` | Shared logins, cache, queues, locks | Logged out on the other pod; jobs run twice |
| Database issue indexer | `helmfile/values/gitea.yaml.gotmpl` | Search works with two pods | bleve opens on one pod only |
| Shared SSH host key | `bootstrap/state`, `helmfile/charts/gitea-config` | Same SSH identity on both pods | SSH refuses every other connection |
| Per-pod `app.ini` | `helmfile/values/gitea.yaml.gotmpl`, `helmfile/helmfile.yaml.gotmpl` | Each pod builds its own config | Pods corrupt one shared file on a fresh install |
| Shared signing keys (`gitea-<suffix>/app-ini-keys`) | `bootstrap/state`, `helmfile/charts/gitea-config` | Same keys on both pods | Cookies and tokens fail across pods |
| Folders made before Gitea starts; OAuth2 `HS256` | `helmfile/values/gitea.yaml.gotmpl` | No folder or key file races on a fresh install | A pod restarts on first start |
| Readiness probe `GET /api/v1/version` | `helmfile/values/gitea.yaml.gotmpl` | Only a working pod gets traffic | A broken pod passes the stock port check |
| `maxSurge: 1` | `helmfile/values/gitea.yaml.gotmpl` | Start a new pod before stopping an old one | An old pod could stop first |
| `maxUnavailable: 0` | same | Never fewer than 2 ready pods | Could drop to 1 or 0 |
| Disruption budget, `minAvailable: 1` | same | AWS node maintenance can't stop both pods | Both pods could go at once |
| Readiness gates | `helmfile/charts/gitea-cluster/templates/namespace.yaml` | Ready only once the load balancers send traffic | An old pod could stop too early |
| 60 s preStop pause | `helmfile/helmfile.yaml.gotmpl` | A stopping pod keeps serving while traffic moves | New connections refused (a 15 s pause dropped one) |
| 300 s load balancer drain | `helmfile/values/gitea.yaml.gotmpl` | Open connections finish | Long clones and pushes cut |
| 300 s graceful shutdown, 360 s grace period | same | Gitea finishes open requests | Killed mid-request |

`maxSurge` and `maxUnavailable` control upgrades. The disruption budget covers the times AWS
moves pods on its own, like replacing a node.

## What happens during an upgrade

Old pods are A and B. New pods are C and D. Every pod mounts the same EFS volume and has its own
`app.ini`.

**Phase 0, steady state.** A and B serve everything. Both are healthy in the ALB (HTTP, checked
on `/api/healthz` every 15 s) and the NLB (SSH, TCP check every 10 s).

**Phase 1, merge.** The new `gitea_version` reaches the cluster. Kubernetes creates C. That's 3
pods, which `maxSurge: 1` allows. A and B keep serving.

**Phase 2, C starts up.** C's init containers run first: `init-directories` makes the folders,
`init-app-ini` writes C's `app.ini`, and `configure-gitea` runs `gitea migrate` and checks the
admin user. C gets no traffic yet.

**Phase 3, C is checked.** Gitea starts in C. Kubernetes' readiness probe (`GET /api/v1/version`
every 10 s) passes. The load balancers run their own checks. C stays not-ready until both pass
(its readiness gates): about 30 s for each. The liveness probe only restarts a hung pod; it
doesn't decide traffic.

**Phase 4, C serves.** Both gates pass. C is ready and gets traffic. Three pods serve.

**Phase 5, A is told to stop.** 2 pods are still ready, so Kubernetes may stop A. A leaves the
Service right away. The controller starts removing it from the load balancers, which takes about
15 s or more. Meanwhile A runs a 60 s pause and keeps serving, so anything that still reaches it
works.

**Phase 6, A shuts down.** After 60 s, Gitea in A gets the stop signal. It takes no new work and
finishes open requests, clones and pushes, for up to 300 s. The load balancers keep those
connections open for the same 300 s. Kubernetes force-kills only after 360 s.

**Phase 7, B is replaced.** D replaces B the same way. At no point are fewer than 2 pods
serving.

Every connection is covered. One that reaches A before the load balancers stop routing to it is
served during the pause. One already open finishes during shutdown. One that arrives later goes
to the ready pods. The one gap: a single clone or push longer than 5 minutes gets cut. Longer
limits fix that.

Merge to finished rollout: about 3.5 minutes.

### The database during an upgrade

A new version can change the database tables. The chart handles it: every pod's
`configure-gitea` init container runs `gitea migrate` before Gitea starts.

- Only one pod migrates. With `maxSurge: 1`, one new pod starts at a time. The next one finds
  nothing to do.
- Nothing kills it halfway. Health probes watch the Gitea container, not init containers.
- A failed migration causes no outage. The new pod never becomes ready, so the old pods keep
  serving. The deploy fails in CI.
- A version set lower by mistake ends the same way. Gitea refuses to start on newer tables.
- The old pods keep working on the updated tables until they're replaced. That held in both
  upgrade tests.

The database itself is never restarted during an upgrade.

To roll back, don't lower the version. Restore the database with RDS point-in-time recovery to a
minute before the upgrade.

## Where we differ from the stock Gitea chart

We use the official chart (`gitea-charts/gitea` 12.7.0) as is. We set values in
`helmfile/values/gitea.yaml.gotmpl`, and Helmfile applies one patch after rendering. The rest of
`helmfile/` is ours: two small charts and External Secrets.

| Setting | Stock chart | Ours | Why |
| --- | --- | --- | --- |
| `replicaCount` | 1 | 2 | One pod serves while the other is replaced |
| `maxSurge` | 100% | 1 | One new pod at a time |
| `maxUnavailable` | 0 | 0 (explicit) | Never fewer ready pods than replicas |
| `podDisruptionBudget` | none | `minAvailable: 1` | Node maintenance can't take both pods |
| `topologySpreadConstraints` | none | prefer different AZs | One AZ down usually leaves a pod |
| `persistence` | a 10 Gi ReadWriteOnce claim | our ReadWriteMany EFS claim | Both pods share the repos |
| Extra volumes and mounts | none | SSH host key; per-pod `app.ini` | Shared SSH identity; no shared config file |
| `initPreScript` | empty | `mkdir -p` of every folder on `/data` | No folder races on a fresh install |
| `gitea.readinessProbe` | TCP on the HTTP port | `GET /api/v1/version` | Catches a broken pod |
| `terminationGracePeriodSeconds` | 60 | 360 | Room for the pause and graceful shutdown |
| `service.ssh` | ClusterIP | LoadBalancer on the NLB, 300 s drain | SSH from outside |
| `ingress` | off | ALB, `/api/healthz` check, 300 s drain | Web and git over HTTP from outside |
| `postgresql-ha`, `valkey-cluster` | on | off; RDS and ElastiCache | Data outside the cluster |
| `test` | on | off | No chart test pod |
| Security contexts | empty | non-root, no privilege escalation, no capabilities | Hardening |
| `resources` | none | 250m CPU, 512 Mi requested, 1 Gi limit | Predictable scheduling |
| `image.tag` | chart default | `gitea_version` from `aws/main.tf` | Version chosen in one place |
| `gitea.admin` | a fixed password in the chart's values | random password from Secrets Manager | No password in Git |
| `gitea.additionalConfigSources` | none | database password, Valkey URLs, metrics token, signing keys | Secrets stay out of Git |
| `gitea.config` | defaults | RDS with TLS; Valkey for cache, session, queue, lock; `db` indexer; SSH on 2222; OAuth2 `HS256`; registration off | Shared state; no domain |
| Pod lifecycle | no preStop | `preStop: sleep 60` (Helmfile patch) | The chart has no setting for it |
| `init-directories` mounts | all extra mounts | no per-pod `app.ini` mount (Helmfile patch) | Avoids a mount race on a fresh install |

Outside the chart, a namespace label turns on Auto Mode's readiness gates
(`eks.amazonaws.com/pod-readiness-gate-inject: enabled`).

## A fresh install: two pods starting together

Upgrades start one pod at a time, so they never hit these. A brand-new install does: both pods
start at the same second, on an empty disk and an empty database. Testing from scratch found
these.

1. Both pods wrote one `app.ini`. The chart keeps it on the shared disk, and each pod
   rewrites it at start. One pod read it half-written, started the setup page, and returned 404
   for every API call. Fix: each pod gets its own `app.ini` on a per-pod volume.
2. Each pod made its own signing keys, so the pods could sign cookies and tokens differently.
   Fix: the bootstrap makes the four keys once (`gitea-<suffix>/app-ini-keys`); every pod uses
   them.
3. Both pods created Gitea's folders. `mkdir /data/home: file exists`, then `/data/jwt`. The
   loser restarted. Fix: `initPreScript` creates every folder first with `mkdir -p`.
4. Each pod made its own OAuth2 key file in `/data/jwt`. Fix: OAuth2 signs with the shared
   `JWT_SECRET` (`HS256`); no key file.
5. Both pods created the per-pod mount point on the shared disk. `error mounting ... no such
   file or directory`. Fix: a patch keeps that mount off the first init container, which
   creates the folder itself.

Known and accepted: both pods run `gitea migrate` on the empty database at once. One can hit
`relation ... already exists`, retry a few seconds later and start fine. It happens once per new
environment, before anyone uses Gitea. Upgrades never hit it.

If one of these still happens, the readiness probe fails on the broken pod, so it never gets
traffic.

We checked this with fresh installs in an empty AWS account. Each pod had its own `app.ini` and
the same keys, the admin could log in on each, 40 of 40 logins through the ALB worked, and no
container had restarted.

## How we know it works

`scripts/zero-downtime-upgrade-healthcheck.sh` runs from before the merge until 90 s after the
last pod is replaced. Through the public load balancers it loads `/api/healthz` every second.
Every 3 seconds it runs `git ls-remote` over HTTP and SSH, pushes a commit over SSH, and creates
an issue through the API. Any error or timeout counts as a failure.

These runs were on a fresh clone of the template, in a new repo, with every fix above in place.

| Upgrade | Checks | Failed | Merge to rollout done |
| --- | --- | --- | --- |
| Minor, 1.26.3 to 1.27.3 | 829 | 0 | 3 min 56 s |
| Major, 1.27.3 to 28.2.0 | 866 | 0 | 3 min 55 s |

A real repo (spf13/cobra, 1,106 commits) cloned the same before and after. 40 logins in a row
all worked. After both upgrades, no Gitea container or init container had restarted.

The check samples every 1 to 3 seconds. A gap shorter than that could slip between two checks.

## Demo limitations

These parts are kept single to save cost. Upgrades never touch them, and each has a known fix.

- One database, in one AZ. AWS maintenance or a failure takes it down for a few minutes.
  Multi-AZ RDS cuts that to about 40 s. RDS Proxy would turn those seconds into slow requests.
- One Valkey node. If it restarts, users get logged out and queued jobs are lost.
- Pods can share a node. Upgrades are fine. Losing that node causes a short outage.
- HTTP only, with no domain. Gitea's UI shows `git@localhost:...` as the SSH clone URL.

## Alternatives we didn't take

- One pod on EBS with `Recreate`. It's the simplest and most common setup, but every deploy is an
  outage.
- A StatefulSet with a disk per pod. Each pod's copy of the repos would drift apart.
- The chart's built-in Postgres and Valkey. The data would live in the cluster and be lost with
  it.
