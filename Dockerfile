# GitHub Actions self-hosted runner container. One container = one job: it registers
# an ephemeral runner, runs a single job, and is removed (runners.sh starts a fresh one).
#
# Base: a pinned plain Ubuntu plus exactly what the workflows need — the apt packages
# in packages.txt, the toolchains in toolcache.txt, a Docker engine and the official
# actions/runner. GitHub does not publish its hosted `ubuntu-latest` image as a
# container, so a workflow that needs a tool missing here adds it to packages.txt (or
# installs it in the job). RUNNERS_BASE_IMAGE (runners.sh) swaps the base, e.g. for a
# full toolset replica such as ghcr.io/catthehacker/ubuntu:full-24.04.
ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

ARG RUNNER_VERSION=2.338.2
# SHA-256 of actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz. GitHub publishes it
# only in the release notes (no .sha256 asset); runners.sh reads it from there.
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

LABEL runner.version=${RUNNER_VERSION}
USER root
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# What this Dockerfile itself needs, then the project packages.
COPY packages.txt toolcache.txt /tmp/image/
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git sudo; \
    sed 's/#.*//' /tmp/image/packages.txt | xargs -r apt-get install -y --no-install-recommends; \
    rm -rf /var/lib/apt/lists/*

# Tool cache, in the layout the setup actions look up: <tool>/<version>/x64 plus an
# x64.complete marker. Downloads are checked against the publisher's SHA-256.
RUN set -eu; \
    mkdir -p /opt/hostedtoolcache; \
    sed 's/#.*//' /tmp/image/toolcache.txt | while read -r tool version; do \
      [ -n "$tool" ] || continue; \
      case "$tool" in \
        node) file="node-v$version-linux-x64.tar.xz"; url="https://nodejs.org/dist/v$version/$file"; \
              sum="$(curl -fsSL "https://nodejs.org/dist/v$version/SHASUMS256.txt" | awk -v f="$file" '$2 == f { print $1 }')" ;; \
        go)   file="go$version.linux-amd64.tar.gz"; url="https://dl.google.com/go/$file"; \
              sum="$(curl -fsSL "$url.sha256")" ;; \
        *)    echo "toolcache.txt: unknown tool '$tool'" >&2; exit 1 ;; \
      esac; \
      curl -fsSL -o "/tmp/$file" "$url"; \
      echo "$sum  /tmp/$file" | sha256sum -c -; \
      dir="/opt/hostedtoolcache/$tool/$version/x64"; mkdir -p "$dir"; \
      tar -xf "/tmp/$file" --strip-components=1 -C "$dir"; \
      touch "$dir.complete"; \
      rm -f "/tmp/$file"; \
    done

# Node and Go on PATH, as on a hosted runner, so a step that uses them without a
# setup action still works. The first version of each in toolcache.txt is the
# default; setup-node / setup-go put the version a job asks for ahead of it.
RUN set -eu; \
    for tool in node go; do \
      version="$(awk -v t="$tool" '$1 == t { print $2; exit }' /tmp/image/toolcache.txt)"; \
      [ -n "$version" ] || continue; \
      for bin in "/opt/hostedtoolcache/$tool/$version/x64/bin/"*; do \
        ln -s "$bin" "/usr/local/bin/$(basename "$bin")"; \
      done; \
    done

# The job user: same name and home as GitHub-hosted runners (some base images already
# have it), with passwordless sudo.
RUN id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner; \
    echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner

# Docker engine for the per-job private daemon. Jobs get `docker`, `docker compose`
# and `container:` steps against a daemon that lives and dies with the job — the
# host's container socket is never mounted. Installed only when missing.
RUN if ! command -v dockerd >/dev/null 2>&1 || ! command -v containerd >/dev/null 2>&1; then \
      install -d -m 0755 /etc/apt/keyrings \
      && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
      && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
         > /etc/apt/sources.list.d/docker.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
           docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      && rm -rf /var/lib/apt/lists/*; \
    fi; \
    getent group docker >/dev/null || groupadd docker; \
    usermod -aG docker runner

# The official runner, verified against its published checksum.
RUN set -eux; \
    curl -fsSL -o /tmp/runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum -c -; \
    mkdir -p /home/runner/actions-runner /home/runner/_work; \
    tar -xzf /tmp/runner.tar.gz -C /home/runner/actions-runner; \
    rm -f /tmp/runner.tar.gz; \
    /home/runner/actions-runner/bin/installdependencies.sh; \
    chown -R runner:runner /home/runner /opt/hostedtoolcache

COPY entrypoint.sh /usr/local/bin/gh-runner-entrypoint
RUN chmod 0755 /usr/local/bin/gh-runner-entrypoint
WORKDIR /home/runner/actions-runner
# Runs as root to start the job's Docker daemon, then drops to `runner`.
ENTRYPOINT ["/usr/local/bin/gh-runner-entrypoint"]
