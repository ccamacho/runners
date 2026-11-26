# gh-runners

Self-hosted GitHub Actions runners on one Linux machine. Each runner is an
**ephemeral container that runs exactly one job** and is then replaced, so every
job starts from a clean image, as on GitHub-hosted runners. The image replicates
the `ubuntu-latest` toolset, so workflows move over unchanged.

## How it works

| Piece | What it does |
|---|---|
| `runners.sh` | The one entry point: `setup`, `status`, `update`, `build`, `up`, `down`, `uninstall` |
| `Dockerfile` | `catthehacker/ubuntu:full-latest` (ubuntu-latest replica) + Docker engine + the official `actions/runner`, checksum-verified |
| `entrypoint.sh` | Starts the job's private Docker daemon, registers an ephemeral runner, runs one job as `runner` |
| `repos.example.txt` | Example targets. Copy to `repos.txt` (not committed) and edit |
| `install-gh.sh` | Installs the GitHub CLI to `~/bin` (no sudo) |

`runners.sh setup` installs two systemd **user** units:

- `gh-runners.service` keeps one container per runner slot alive. When a
  container finishes its job and exits, a fresh one registers in its place.
- `gh-runner-update.timer` (Sunday 04:00, catches up after the machine was off)
  pulls the base toolset and rebuilds with the latest runner release. New
  containers use the new image; running jobs are never interrupted.

Lingering is enabled so the units start at boot.

### Isolation and resources

- **One job per container.** No workspace, caches, processes or HOME files carry
  over between jobs.
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
bash runners.sh setup          # first run pulls ~19 GB (the toolset image)
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
| `RUNNERS_BASE_IMAGE` | the ubuntu-latest replica |

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
- The base image is a community replica of the GitHub-hosted toolset, not
  published by GitHub. GitHub's official `ghcr.io/actions/actions-runner` is
  minimal by comparison; set `RUNNERS_BASE_IMAGE` to an Ubuntu 24.04 image to
  trade parity for disk space.
- Tested with rootless Docker. Podman is supported through the same commands
  (`run`, `ps`, `build`, `image inspect`) but not exercised on this machine.
