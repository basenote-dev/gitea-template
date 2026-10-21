#!/usr/bin/env bash
# Watch Gitea from the outside while a deploy or upgrade runs, to prove it drops nothing.
#
#   scripts/zero-downtime-upgrade-healthcheck.sh
#
# No arguments and no setup: with the AWS credentials you deployed with (only the AWS CLI, git
# and curl needed), it finds Gitea's load balancers by the tags EKS puts on them, reads the
# admin password from Secrets Manager, and creates a repository to test against and a temporary
# SSH key (removed on exit).
#
# Independent loops until Ctrl-C (or DURATION seconds, if set), each every EVERY seconds
# (default 3; healthz every second):
#   healthz          GET /api/healthz
#   https-ls-remote  git ls-remote over HTTP
#   ssh-ls-remote    git ls-remote over SSH, through the NLB
#   ssh-push         a new commit pushed over SSH (lands on EFS, recorded in the database)
#   api-write        an issue created through the API
#
# Every 5 seconds it prints one line: each check's latest result and its ok/fail count so far.
# Failures also print as they happen. At the end it prints the totals and the time of every
# failure, and exits 1 if anything failed. Every single result is kept in
# zero-downtime-healthcheck-<utc time>.log ("<utc time> <check> ok|fail").
set -euo pipefail

every=${EVERY:-3}
duration=${DURATION:-0}
admin=gitea_admin
repo_name=zero-downtime-healthcheck
repo=$admin/$repo_name

work=$(mktemp -d)
log=zero-downtime-healthcheck-$(date -u +%Y%m%dT%H%M%SZ).log
: >"$log"
pids=()
key_id=""

# Where Gitea is: the load balancers EKS Auto Mode made for the Ingress (the account's shared
# ALB, group "sandbox") and for the SSH Service, found by the tags it puts on them.
lb() {
  local arn
  arn=$(aws resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=$1,Values=$2" --query 'ResourceTagMappingList[0].ResourceARN' --output text)
  aws elbv2 describe-load-balancers --load-balancer-arns "$arn" --query 'LoadBalancers[0].DNSName' --output text
}
web_host=$(lb ingress.eks.amazonaws.com/stack sandbox)
ssh_host=$(lb service.eks.amazonaws.com/stack gitea/gitea-ssh)
url=http://$web_host

# Admin credentials in a netrc file, so the password never shows up in the process list.
umask 077
printf 'machine %s login %s password %s\n' "$web_host" "$admin" \
  "$(aws secretsmanager get-secret-value --secret-id gitea/admin --query SecretString --output text)" >"$work/netrc"
api() { curl -fsS --max-time 5 --netrc-file "$work/netrc" -H 'Content-Type: application/json' "$@"; }

cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  [ -n "$key_id" ] && api -X DELETE "$url/api/v1/user/keys/$key_id" >/dev/null 2>&1 || true
  rm -rf "$work"
}

summary() {
  trap - INT TERM EXIT
  cleanup
  echo
  echo "Summary ($(head -1 "$log" | cut -d' ' -f1) to $(tail -1 "$log" | cut -d' ' -f1)):"
  local failed=0
  for name in "${checks[@]}"; do
    local ok fail
    ok=$(grep -c " $name ok$" "$log" || true)
    fail=$(grep -c " $name fail$" "$log" || true)
    printf '  %-16s ok=%-5s fail=%s\n' "$name" "$ok" "$fail"
    if [ "$fail" -gt 0 ]; then
      failed=1
      grep " $name fail$" "$log" | cut -d' ' -f1 | sed 's/^/    failed at /'
    fi
  done
  echo "Every result: $log"
  exit "$failed"
}
checks=(healthz https-ls-remote ssh-ls-remote ssh-push api-write)
trap summary INT TERM EXIT

# A repository to test against (kept between runs) and a temporary SSH key for the admin user.
api "$url/api/v1/repos/$repo" >/dev/null 2>&1 ||
  api -X POST -d "{\"name\":\"$repo_name\",\"auto_init\":true}" "$url/api/v1/user/repos" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C "$repo_name" -f "$work/key"
key_id=$(api -X POST -d "{\"title\":\"$repo_name-$(date -u +%s)\",\"key\":\"$(cat "$work/key.pub")\"}" \
  "$url/api/v1/user/keys" | sed -E 's/^\{"id":([0-9]+).*/\1/')

export GIT_TERMINAL_PROMPT=0
# Give up on a stalled transfer after ~10s instead of hanging (no `timeout` on macOS).
export GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$work/known_hosts"

# probe <name> <interval> <command...>: append "<utc time> <name> ok|fail" to the log.
probe() {
  local name=$1 interval=$2
  shift 2
  while :; do
    local t
    t=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if "$@" >/dev/null 2>&1; then
      echo "$t $name ok" >>"$log"
    else
      echo "$t $name fail" >>"$log"
      echo "$t FAIL $name"
    fi
    sleep "$interval"
  done
}

git clone -q "git@$ssh_host:$repo.git" "$work/repo"
git -C "$work/repo" checkout -q -b "healthcheck-$(date -u +%Y%m%d%H%M%S)"
push() {
  git -C "$work/repo" -c user.name=healthcheck -c user.email=healthcheck@example.com \
    commit -q --allow-empty -m "healthcheck $(date -u +%H:%M:%S)" &&
    git -C "$work/repo" push -q -u origin HEAD
}

echo "Gitea $url  SSH git@$ssh_host  (Ctrl-C to stop)"
echo "Every 5s: check, latest result, ok/fail so far."
probe healthz 1 curl -fsS --max-time 3 "$url/api/healthz" &
pids+=($!)
probe https-ls-remote "$every" git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 ls-remote "$url/$repo.git" &
pids+=($!)
probe ssh-ls-remote "$every" git ls-remote "git@$ssh_host:$repo.git" &
pids+=($!)
probe ssh-push "$every" push &
pids+=($!)
probe api-write "$every" api -X POST -d '{"title":"healthcheck"}' "$url/api/v1/repos/$repo/issues" &
pids+=($!)

status() {
  while :; do
    sleep 5
    local line
    line=$(date -u +%H:%M:%S)
    for name in "${checks[@]}"; do
      local last ok fail
      last=$(grep " $name " "$log" | tail -1 | cut -d' ' -f3)
      ok=$(grep -c " $name ok$" "$log" || true)
      fail=$(grep -c " $name fail$" "$log" || true)
      line+=$(printf '  %s %-4s %7s' "$name" "${last:--}" "$ok/$fail")
    done
    echo "$line"
  done
}
status &
pids+=($!)

if [ "$duration" -gt 0 ]; then
  sleep "$duration"
else
  wait
fi
