# ADR 0001: Zero-downtime Gitea upgrades

Status: accepted, 2026-10-21

## Decision

Gitea runs as 2 identical pods that keep no state of their own. An upgrade replaces them one at
a time, so one pod is always serving. One pod would leave a gap on every upgrade. A third would
add cost without making upgrades safer.

## Where the state lives

| State | Where | Why |
| --- | --- | --- |
| Repos, LFS, attachments | EFS | Both pods need the same files at once. EBS attaches to one node only (tested: AWS refuses a shared EBS volume) |
| Users, issues, pull requests | RDS PostgreSQL | One shared database |
| Sessions, cache, queues, locks | ElastiCache Valkey | Gitea keeps these in memory by default, so each pod would have its own |
| Issue search index | RDS (`db` indexer) | The default index (bleve) opens on one pod only |
| SSH host key | Secrets Manager | With a key per pod, SSH clients refuse every other connection |
| Signing keys | Secrets Manager | With keys per pod, cookies and tokens fail across pods |

## Rollout settings

| Setting | Why |
| --- | --- |
| `maxSurge: 1`, `maxUnavailable: 0` | Start a new pod before stopping an old one, never fewer than 2 ready |
| Readiness probe `GET /api/v1/version` | The stock TCP check passes on a broken pod |
| Readiness gates (namespace label) | A pod counts as ready only once the load balancers send it traffic |
| `preStop: sleep 60` | A stopping pod keeps serving while the load balancers move traffic off it |
| 300 s graceful shutdown, 300 s load balancer drain, 360 s grace period | Open clones and pushes finish before the pod exits |
| Disruption budget `minAvailable: 1` | Node replacements can't take both pods at once |
| Topology spread across AZs (preferred) | One AZ outage usually leaves a pod |

The disruption budget doesn't limit upgrades. It covers the times AWS moves pods on its own.

## Fresh-install fixes

A new install starts both pods at the same second on an empty volume. That caused races that
upgrades never hit, each fixed once:

- Each pod gets its own `app.ini` on a per-pod volume. With one shared file, a pod read it half
  written.
- `initPreScript` creates Gitea's folders before Gitea starts. Two pods creating them crashed one.
- OAuth2 signs with the shared `JWT_SECRET` (`HS256`), so there's no key file to race on.
- A Helmfile patch keeps the per-pod mount off the first init container, which creates that
  folder itself.

Both pods can run `gitea migrate` on the empty database at once. One may retry and then start.
This happens once per new install.

## Database migrations

The first new pod runs `gitea migrate` in an init container before Gitea starts, and the old
pods keep working on the updated tables. If a migration fails, that pod never becomes ready and
the old pods keep serving. To roll back, restore the database with RDS point-in-time recovery.
Lowering the version doesn't work, because Gitea won't start on tables a newer version changed.

## Tested

`scripts/zero-downtime-upgrade-healthcheck.sh` ran through each rollout, from before the merge
to after the last pod was replaced.

| Upgrade | Checks | Failed |
| --- | --- | --- |
| 1.26.3 to 1.27.3 | 829 | 0 |
| 1.27.3 to 28.2.0 | 866 | 0 |
| 1.26.3 to 1.26.4 | 960 | 0 |

The check runs every 1 to 3 seconds, so a shorter gap could fall between two checks.

## Not covered

These are kept single to save cost. Upgrades don't touch them.

- RDS is in one AZ. Maintenance takes it down for a few minutes. Multi-AZ cuts that to about
  40 seconds.
- Valkey is one node. A restart logs users out and drops queued jobs.
- Both pods can land on one node. Losing that node is a short outage.
- No domain, so HTTP only, and Gitea shows `git@localhost:...` as the SSH clone URL.
