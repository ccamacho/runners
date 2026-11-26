# GitHub Actions self-hosted runner container. One container = one job: it registers
# an ephemeral runner, runs a single job, and is removed (runners.sh starts a fresh one).
#
# Base: catthehacker/ubuntu:full-latest — community replica of the GitHub-hosted
# ubuntu-latest toolset (node, python, go, java, browsers, CLIs, ...), so workflows
# move over unchanged. The tag tracks whatever ubuntu-latest currently is (26.04 at
# the time of writing). ~19 GB compressed. Set RUNNERS_BASE_IMAGE (runners.sh) to a
# smaller pinned Ubuntu image if disk matters more than toolset parity.
ARG BASE_IMAGE=ghcr.io/catthehacker/ubuntu:full-latest
FROM ${BASE_IMAGE}

ARG RUNNER_VERSION=2.338.2
# SHA-256 of actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz. GitHub publishes it
# only in the release notes (no .sha256 asset); runners.sh reads it from there.
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

LABEL runner.version=${RUNNER_VERSION}
USER root
ENV DEBIAN_FRONTEND=noninteractive

# The job user: same name and home as GitHub-hosted runners (it already exists in
# catthehacker images; created if the base image changes), with passwordless sudo.
RUN id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner; \
    echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner

# Docker engine for the per-job private daemon. Jobs get `docker`, `docker compose`
# and `container:` steps against a daemon that lives and dies with the job — the
# host's container socket is never mounted. Installed only when missing.
RUN if ! command -v dockerd >/dev/null 2>&1 || ! command -v containerd >/dev/null 2>&1; then \
      install -d -m 0755 /etc/apt/keyrings \
      && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
      && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
         > /etc/apt/sources.list.d/docker.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
           docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin iptables \
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
    chown -R runner:runner /home/runner

COPY entrypoint.sh /usr/local/bin/gh-runner-entrypoint
RUN chmod 0755 /usr/local/bin/gh-runner-entrypoint
WORKDIR /home/runner/actions-runner
# Runs as root to start the job's Docker daemon, then drops to `runner`.
ENTRYPOINT ["/usr/local/bin/gh-runner-entrypoint"]
