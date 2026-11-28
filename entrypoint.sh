#!/bin/bash
# Runner container entrypoint (runs as root). Starts this job's private Docker daemon,
# registers an EPHEMERAL runner, and runs exactly one job as the `runner` user.
#
# Env (set by runners.sh; exactly one of ORG / REPO):
#   ORG            org-level runner — https://github.com/ORG (the organizations/
#                  form GitHub's docs show gets 404 from the registration API)
#   REPO           repo-level runner — https://github.com/REPO
#   TOKEN          one-hour registration token (removed from the env before anything runs)
#   RUNNER_NAME    runner name (unique per container)
#   RUNNER_LABELS  optional extra labels, comma-separated (self-hosted/Linux/X64 are automatic)
#   RUNNER_CPUSET  optional CPU list to pin the job to, e.g. "3-5" or "3,4,5"
#   RUNNER_DOCKER  "off" skips the per-job Docker daemon
#   RUNNER_CACHE_DIR  optional mounted directory that outlives the container. Jobs see
#                  the same variable; npm keeps its download cache there.
set -euo pipefail

if [ -n "${ORG:-}" ]; then
  url="https://github.com/${ORG}"
elif [ -n "${REPO:-}" ]; then
  url="https://github.com/${REPO}"
else
  echo "gh-runner: either ORG or REPO must be set" >&2
  exit 1
fi
: "${RUNNER_NAME:?}"
# Take the token out of the environment first, so neither dockerd nor the job can
# read it from its own environment.
token="${TOKEN:?TOKEN (registration token) is required}"
unset TOKEN

if [ "${RUNNER_DOCKER:-on}" != "off" ]; then
  dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
  if ! docker info >/dev/null 2>&1; then
    echo "gh-runner: the per-job Docker daemon did not start:" >&2
    tail -n 40 /var/log/dockerd.log >&2
    exit 1
  fi
fi

if [ -n "${RUNNER_CACHE_DIR:-}" ]; then
  mkdir -p "$RUNNER_CACHE_DIR/npm"
  # Files unused for two weeks go, so the volume stays bounded. (Users of the cache
  # touch what they read.)
  find "$RUNNER_CACHE_DIR" -type f -mtime +14 -delete 2>/dev/null || true
  chown runner:runner "$RUNNER_CACHE_DIR" "$RUNNER_CACHE_DIR/npm"
  export npm_config_cache="$RUNNER_CACHE_DIR/npm"
fi

cd /home/runner/actions-runner
labels=()
if [ -n "${RUNNER_LABELS:-}" ]; then labels=(--labels "$RUNNER_LABELS"); fi
setpriv --reuid=runner --regid=runner --init-groups env HOME=/home/runner \
  ./config.sh --unattended --ephemeral --disableupdate --replace \
  --url "$url" --token "$token" --name "$RUNNER_NAME" "${labels[@]}" \
  --work /home/runner/_work
unset token

# Pin the job to this runner's own cores. A CPU quota alone still shows the job every
# host core, so test runners (node --test, make -j, pytest -n auto) start one worker
# per HOST core inside a few cores' worth of CPU — the overload that makes timing
# tests flaky. Affinity makes nproc / availableParallelism() report the real budget.
pin=()
if [ -n "${RUNNER_CPUSET:-}" ]; then pin=(taskset -c "$RUNNER_CPUSET"); fi

# setpriv keeps the image's environment (the toolset's PATH, ImageOS, …) intact; only
# the identity changes.
export HOME=/home/runner USER=runner LOGNAME=runner
exec "${pin[@]}" setpriv --reuid=runner --regid=runner --init-groups ./run.sh
