# gh-runners

Self-hosted GitHub Actions runners on one Linux machine. Each runner is an
**ephemeral container that runs exactly one job** and is then replaced, so every
job starts from a clean image, as on GitHub-hosted runners. The image is a pinned
Ubuntu plus the packages your workflows need, listed in this repo.

## How it works

| Piece | What it does |
|---|---|
| `runners.sh` | The one entry point: `setup`, `status`, `update`, `build`, `up`, `down`, `uninstall` |
| `Dockerfile` | `ubuntu:26.04` + the files below + Docker engine + the official `actions/runner`, checksum-verified |
| `packages.txt` | The apt packages baked into the image |
| `toolcache.txt` | Node/Go versions pre-seeded for `actions/setup-node` / `setup-go`, checksum-verified |
| `entrypoint.sh` | Starts the job's private Docker daemon, registers an ephemeral runner, runs one job as `runner` |
| `repos.example.txt` | Example targets. Copy to `repos.txt` (not committed) and edit |
| `install-gh.sh` | Installs the GitHub CLI to `~/bin` (no sudo) |

`runners.sh setup` installs two systemd **user** units:

- `gh-runners.service` keeps one container per runner slot alive. When a
  container finishes its job and exits, a fresh one registers in its place.
- `gh-runner-update.timer` (Sunday 04:00, catches up after the machine was off)
  pulls the base image and rebuilds with the latest runner release. New
  containers use the new image; running jobs are never interrupted.

Lingering is enabled so the units start at boot.

### Isolation and resources

- **One job per container.** No workspace, processes or HOME files carry over
  between jobs. The one exception is the download cache below.
- **Private Docker daemon per job.** Jobs can use `docker`, `docker compose` and
  `container:` steps against a daemon that lives and dies with the job. The
  host's container socket and home directory are never mounted, so a job cannot
  reach the host's containers or files. The runner container is privileged for
  this, which under rootless Docker/Podman is still confined to your user's
  namespace.
- **The GitHub token stays on the host.** A container only receives a one-hour
  registration token, removed from its environment before the job starts.
- **CPU and memory caps, with each runner pinned to its own cores.** Without
  pinning a job sees every host core, and test runners (`node --test`,
  `make -j`, `pytest -n auto`) start one worker per host core inside a
  few-core quota, which makes timing-sensitive tests flaky.

## Setup on a new machine

```bash
# Docker (rootless is fine) or Podman, plus the GitHub CLI:
bash install-gh.sh
gh auth login                  # an admin of the target repos (orgs: admin:org scope)

cp repos.example.txt repos.txt # then edit the targets
bash runners.sh setup          # builds the image on the first run
bash runners.sh status
```

### Targets (`repos.txt`)

| Line | Meaning |
|---|---|
| `owner/repo` | one runner registered to that repo |
| `owner/repo:6` | six runners for that repo (six jobs in parallel) |
| `myorg` | one org-level runner serving the org's repos |
| `myorg:4` | four org-level runners |

Rerun `bash runners.sh setup` after editing.

Org-level runners need a token with the `admin:org` scope
(`gh auth refresh -s admin:org`) and serve repos through **runner groups**: if
jobs queue but never start, check org Settings → Actions → Runner groups →
Default → Repository access.

### Tuning

Set before `setup` (it records them in `~/.config/gh-runners/env`):

| Variable | Default |
|---|---|
| `RUNNERS_CPUS` | cores ÷ number of runners (min 2) |
| `RUNNERS_MEMORY` | `6g` per runner |
| `RUNNERS_LABELS` | none (labels `self-hosted`, `Linux`, `X64` are automatic) |
| `RUNNERS_ENGINE` | `docker` if installed, else `podman` |
| `RUNNERS_BASE_IMAGE` | `ubuntu:26.04` |

### Local download cache

Every container is new, so without a local cache each job downloads its
dependencies again, which on a home connection can use up a job's whole time
limit. Each target therefore gets a volume, `gh-runner-cache-<target>`, mounted at
`/var/cache/gh-runner` and exported to jobs as `RUNNER_CACHE_DIR`. npm's download
cache lives there, and a workflow can keep other archives there (key them by a
lockfile hash, write to a temporary file and rename, and `touch` what you read).
Files unused for 14 days are deleted.

This weakens isolation: a job can change what later jobs **of the same target**
read from the cache. Repos never share a volume, but an org-level target is one
target for all its repos. Set `RUNNERS_CACHE=off` before `setup` to disable it,
and clear it with `docker volume rm gh-runner-cache-<target>` while the pool is
stopped.

### Starting at boot without a login

Registering an ephemeral runner needs a GitHub token for every job. By default
that comes from `gh`'s login, which lives in your keyring and is only unlocked
in a logged-in session. To have runners work right after boot, store a token
the services can read:

```bash
install -m 600 /dev/null ~/.config/gh-runners/token
# paste a fine-grained token with "Administration: write" on the target repos
# (or a classic token with repo / admin:org) into that file
```

## Switching a workflow to these runners

Use a **repository variable**, so moving between GitHub-hosted and self-hosted is a
one-command change, with no workflow edit:

```yaml
jobs:
  test:
    runs-on: ${{ vars.LINUX_RUNNER || 'ubuntu-latest' }}
```

```bash
gh variable set LINUX_RUNNER --body self-hosted --repo owner/repo   # use this machine
gh variable delete LINUX_RUNNER --repo owner/repo                   # back to GitHub-hosted
```

For a matrix with several OSes, route only its Linux leg:

```yaml
    runs-on: ${{ matrix.os == 'ubuntu-latest' && (vars.LINUX_RUNNER || 'ubuntu-latest') || matrix.os }}
```

Keep these on `ubuntu-latest`: **jobs that use secrets** (release keys,
publishing tokens), so the secrets never reach this machine, and macOS or
Windows jobs. While the machine is off or asleep, routed jobs queue and wait for
it; delete the variable to fall back.

## Day-to-day

```bash
bash runners.sh status                 # containers here + registrations on GitHub
journalctl --user -fu gh-runners       # pool log
bash runners.sh update                 # rebuild now instead of waiting for Sunday
bash runners.sh down                   # stop everything (in-flight jobs fail)
bash runners.sh uninstall              # remove the services too
```

## Caveats

- **Private repos only.** Never route a public repo's jobs here: pull requests
  from forks would run arbitrary code on this machine. The same applies to
  org-level runners — keep public repos out of their runner group.
- This is **not** the GitHub-hosted toolset (GitHub does not publish that image as a
  container). A workflow that assumes a preinstalled tool fails here until the tool
  is added to `packages.txt` or installed by the job. `ImageOS` is unset. For
  near-parity instead, set `RUNNERS_BASE_IMAGE` to a replica such as
  `ghcr.io/catthehacker/ubuntu:full-24.04` (tens of GB).
- Tested with rootless Docker. Podman is supported through the same commands
  (`run`, `ps`, `build`, `image inspect`) but not exercised on this machine.
