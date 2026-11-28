#!/usr/bin/env bash
# Self-hosted GitHub Actions runners on this machine: ephemeral containers, one job each.
#
#   runners.sh setup       build the image if needed, install + start the systemd user
#                          services (the runner pool and the weekly update timer).
#                          Idempotent: rerun after editing repos.txt.
#   runners.sh status      runner containers here + the runners GitHub sees
#   runners.sh update      pull the base image, rebuild with the latest runner release
#                          (new containers pick it up; running jobs are not touched)
#   runners.sh build [V]   build the image with runner version V (default: latest)
#   runners.sh up          run the pool in the foreground (what the service runs)
#   runners.sh down        stop every runner container (in-flight jobs fail) and remove
#                          this machine's registrations
#   runners.sh uninstall   stop + remove the services, then `down`
#
# Targets come from repos.txt (copy repos.example.txt; repos.txt is not committed).
# Tunables (env, or ~/.config/gh-runners/env, which `setup` writes):
#   RUNNERS_CPUS        CPUs per runner (default: cores / number of runners, min 2)
#   RUNNERS_MEMORY      memory cap per runner (default 6g)
#   RUNNERS_LABELS      extra runner labels, comma-separated (default: none — every
#                       runner is labeled self-hosted, Linux, X64 automatically)
#   RUNNERS_ENGINE      docker or podman (default: docker if installed, else podman)
#   RUNNERS_BASE_IMAGE  base image (default: the Dockerfile's, ubuntu:26.04)
#   RUNNERS_IMAGE       image tag (default localhost/gh-runner:latest)
#   RUNNERS_TOKEN_FILE  file holding a GitHub token for registration (default
#                       ~/.config/gh-runners/token). Optional: without it `gh`'s own
#                       login is used, which needs an unlocked keyring (a logged-in
#                       session). With it, runners also come up at boot before login.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gh-runners"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
# shellcheck disable=SC1091
[ -f "$CONF_DIR/env" ] && . "$CONF_DIR/env"

IMAGE="${RUNNERS_IMAGE:-localhost/gh-runner:latest}"
MEMORY="${RUNNERS_MEMORY:-6g}"
LABELS="${RUNNERS_LABELS:-}"
TOKEN_FILE="${RUNNERS_TOKEN_FILE:-$CONF_DIR/token}"
HOST="$(hostname -s)"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "error: $*"; exit 1; }
need() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' is not on PATH ($PATH)"; done; }

# Prefer docker when installed (the tested path); podman otherwise. If neither is
# installed, assume docker: the caller gets a clear "docker is not on PATH" error
# from need(). RUNNERS_ENGINE overrides.
engine() {
  if [ -n "${RUNNERS_ENGINE:-}" ]; then echo "$RUNNERS_ENGINE"
  elif command -v docker >/dev/null 2>&1; then echo docker
  elif command -v podman >/dev/null 2>&1; then echo podman
  else echo docker; fi
}
E="$(engine)"

if [ -z "${GH_TOKEN:-}" ] && [ -r "$TOKEN_FILE" ]; then
  GH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"; export GH_TOKEN
fi

# ── targets ────────────────────────────────────────────────────────────────────────
# One line per runner slot: "<kind> <name> <index> <slug>", kind = org | repo.
slots() {
  local file="$HERE/repos.txt" line target count kind slug i
  [ -f "$file" ] || die "no repos.txt — copy repos.example.txt to repos.txt and edit it"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    target="${line%%:*}"; count=1
    [ "$target" != "$line" ] && count="${line##*:}"
    [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 1 ] || die "invalid target '$line' (expected org, org:N, owner/repo or owner/repo:N)"
    if [[ "$target" == */* ]]; then kind=repo; slug="$(echo "$target" | tr '/.' '--')"
    else kind=org; slug="org-$target"; fi
    for (( i = 1; i <= count; i++ )); do echo "$kind $target $i $slug"; done
  done < "$file"
}

api_base() { if [ "$1" = org ]; then echo "orgs/$2"; else echo "repos/$2"; fi; }

# ── image ──────────────────────────────────────────────────────────────────────────
cmd_build() {
  local pull="${PULL:-}" version="${1:-}" sha=''
  if [ -z "$version" ]; then
    version="$(gh api repos/actions/runner/releases/latest --jq '.tag_name | ltrimstr("v")' 2>/dev/null || true)"
  fi
  if [ -n "$version" ]; then
    # GitHub publishes the checksum in the release notes, not as an asset.
    sha="$(gh api "repos/actions/runner/releases/tags/v$version" --jq '.body' 2>/dev/null \
      | sed -n 's/.*<!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p' | head -1)"
    [ -n "$sha" ] || die "no linux-x64 checksum in the v$version release notes"
  fi
  log "building $IMAGE with $E (runner ${version:-Dockerfile default})"
  # shellcheck disable=SC2086
  "$E" build $pull -t "$IMAGE" \
    ${RUNNERS_BASE_IMAGE:+--build-arg BASE_IMAGE="$RUNNERS_BASE_IMAGE"} \
    ${version:+--build-arg RUNNER_VERSION="$version"} \
    ${sha:+--build-arg RUNNER_SHA256="$sha"} \
    "$HERE"
}

cmd_update() {
  PULL=--pull cmd_build "$@"
  "$E" image prune -f >/dev/null 2>&1 || true
  log "updated; new runner containers use the new image (running jobs are untouched)"
}

# ── the pool ───────────────────────────────────────────────────────────────────────
cpus_per_runner() {
  local total=$1
  if [ -n "${RUNNERS_CPUS:-}" ]; then echo "$RUNNERS_CPUS"; return; fi
  local c=$(( $(nproc) / total ))
  (( c < 2 )) && c=2
  echo "$c"
}

# Cores for global slot n (0-based): consecutive blocks of $cpus, wrapping around.
cpuset_for() {
  local n=$1 cpus=$2 cores start c list=()
  cores="$(nproc)"; start=$(( (n * cpus) % cores ))
  for (( c = 0; c < cpus && c < cores; c++ )); do list+=( $(( (start + c) % cores )) ); done
  (IFS=,; echo "${list[*]}")
}

start_slot() {
  local kind=$1 target=$2 i=$3 slug=$4 n=$5 cpus=$6 token
  token="$(gh api -X POST "$(api_base "$kind" "$target")/actions/runners/registration-token" --jq .token)" || return 1
  local who=(-e "REPO=$target"); [ "$kind" = org ] && who=(-e "ORG=$target")
  # The token reaches the container through the engine's environment, never argv
  # (visible in `ps`).
  TOKEN="$token" "$E" run -d --rm --privileged \
    --name "gh-runner-$slug-$i" --label gh-runner=1 \
    --cpus "$cpus" --memory "$MEMORY" --pids-limit 16384 \
    -v /var/lib/docker \
    -e TOKEN "${who[@]}" \
    -e RUNNER_NAME="$HOST-$slug-$i-$(date +%s)" \
    -e RUNNER_LABELS="$LABELS" \
    -e RUNNER_CPUSET="$(cpuset_for "$n" "$cpus")" \
    "$IMAGE" >/dev/null
}

running() { [ -n "$("$E" ps -q --filter "name=^gh-runner-$1-$2\$")" ]; }

# Remove this machine's leftover registrations (a container killed mid-job stays
# registered). Default: offline ones only — live containers own the rest. `all`: after
# every container here was removed (GitHub keeps a vanished runner "online" a while).
prune() {
  local mode="${1:-}" kind target slug filter ids id seen=' '
  filter='.status == "offline" and '; [ "$mode" = all ] && filter=''
  while read -r kind target _ slug; do
    case "$seen" in *" $kind:$target "*) continue ;; esac
    seen="$seen$kind:$target "
    ids="$(gh api --paginate "$(api_base "$kind" "$target")/actions/runners" \
      --jq ".runners[] | select(${filter}(.name | startswith(\"$HOST-$slug-\"))) | .id" 2>/dev/null || true)"
    for id in $ids; do
      gh api -X DELETE "$(api_base "$kind" "$target")/actions/runners/$id" >/dev/null 2>&1 \
        && log "removed registration $id ($target)"
    done
  done < <(slots)
}

cmd_up() {
  need gh "$E" taskset
  "$E" image inspect "$IMAGE" >/dev/null 2>&1 || cmd_build
  local all total cpus tick=0
  mapfile -t all < <(slots)
  total=${#all[@]}
  (( total > 0 )) || die "repos.txt has no targets"
  cpus="$(cpus_per_runner "$total")"
  trap 'log "stopping"; cmd_down; exit 0' INT TERM
  prune
  log "keeping $total runner(s) online with $E ($cpus CPU / $MEMORY each)"
  while true; do
    local n=0 kind target i slug
    for slot in "${all[@]}"; do
      read -r kind target i slug <<< "$slot"
      if ! running "$slug" "$i"; then
        start_slot "$kind" "$target" "$i" "$slug" "$n" "$cpus" || log "$target #$i: could not start a runner (will retry)"
      fi
      n=$(( n + 1 ))
    done
    tick=$(( tick + 1 ))
    (( tick % 240 == 0 )) && prune # about once an hour
    sleep 15 & wait $!
  done
}

cmd_down() {
  local ids
  ids="$("$E" ps -q --filter label=gh-runner=1)"
  # shellcheck disable=SC2086
  [ -n "$ids" ] && "$E" rm -f $ids >/dev/null
  prune all
}

cmd_status() {
  local kind target slug seen=' '
  echo "runner containers on $HOST ($E):"
  "$E" ps --filter label=gh-runner=1 --format '  {{.Names}}\t{{.Status}}'
  while read -r kind target _ slug; do
    case "$seen" in *" $kind:$target "*) continue ;; esac
    seen="$seen$kind:$target "
    echo "registered on $target:"
    gh api --paginate "$(api_base "$kind" "$target")/actions/runners" \
      --jq ".runners[] | select(.name | startswith(\"$HOST-$slug-\")) | \"  \(.name)\t\(.status)\t\(if .busy then \"busy\" else \"idle\" end)\"" \
      || echo "  (cannot list: an org target needs a token with admin:org)"
  done < <(slots)
}

# ── services ───────────────────────────────────────────────────────────────────────
cmd_setup() {
  need gh "$E" systemctl taskset
  [ "$(slots | wc -l)" -gt 0 ] || die "repos.txt has no targets"
  "$E" image inspect "$IMAGE" >/dev/null 2>&1 || cmd_build

  # The services start with a minimal environment: record where gh and the engine
  # live, how to reach the engine, and any tunables set now.
  mkdir -p "$CONF_DIR" "$UNIT_DIR"
  {
    echo "PATH=$(dirname "$(command -v gh)"):$(dirname "$(command -v "$E")"):/usr/local/bin:/usr/bin:/bin"
    [ -n "${DOCKER_HOST:-}" ] && echo "DOCKER_HOST=$DOCKER_HOST"
    for v in RUNNERS_CPUS RUNNERS_MEMORY RUNNERS_LABELS RUNNERS_ENGINE RUNNERS_BASE_IMAGE RUNNERS_IMAGE RUNNERS_TOKEN_FILE; do
      [ -n "${!v:-}" ] && echo "$v=${!v}"
    done
  } > "$CONF_DIR/env"

  cat > "$UNIT_DIR/gh-runners.service" <<EOF
[Unit]
Description=Self-hosted GitHub Actions runners (ephemeral containers)
After=network-online.target

[Service]
EnvironmentFile=$CONF_DIR/env
ExecStart=$HERE/runners.sh up
Restart=on-failure
RestartSec=30
TimeoutStopSec=120

[Install]
WantedBy=default.target
EOF
  cat > "$UNIT_DIR/gh-runner-update.service" <<EOF
[Unit]
Description=Update the GitHub runner image (base image + latest runner release)

[Service]
Type=oneshot
EnvironmentFile=$CONF_DIR/env
ExecStart=$HERE/runners.sh update
TimeoutStartSec=4h
EOF
  cat > "$UNIT_DIR/gh-runner-update.timer" <<EOF
[Unit]
Description=Weekly update of the GitHub runner image

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Lingering starts the user services at boot without a login.
  if [ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" != yes ]; then
    loginctl enable-linger "$USER" 2>/dev/null || log "warning: could not enable linger; runners start at login only"
  fi
  systemctl --user daemon-reload
  systemctl --user enable gh-runners.service gh-runner-update.timer >/dev/null
  systemctl --user restart gh-runners.service
  systemctl --user start gh-runner-update.timer
  log "running: $(slots | wc -l) runner(s); weekly update Sun 04:00"
  log "logs: journalctl --user -fu gh-runners"
}

cmd_uninstall() {
  systemctl --user disable --now gh-runners.service gh-runner-update.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/gh-runners.service" "$UNIT_DIR/gh-runner-update.service" "$UNIT_DIR/gh-runner-update.timer"
  systemctl --user daemon-reload
  cmd_down
}

case "${1:-}" in
  setup)     cmd_setup ;;
  status)    cmd_status ;;
  update)    shift; cmd_update "$@" ;;
  build)     shift; cmd_build "$@" ;;
  up)        cmd_up ;;
  down)      cmd_down ;;
  uninstall) cmd_uninstall ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
