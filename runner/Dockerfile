# Self-hosted GitHub Actions runner image, generic across the estate.
#
# Base pin: bump the tag here when the estate wants a newer runner release
# (release tag from https://github.com/actions/runner/releases, without the
# leading "v" — that's how ghcr.io/actions/actions-runner tags its images).
# self-update stays ENABLED at container run time (entrypoint.sh execs
# run.sh, never --disableupdate), so this pin only sets the FLOOR version;
# the running binary drifts upward on its own between image rebuilds.
FROM ghcr.io/actions/actions-runner:2.337.0

USER root

# docker-ce-cli / buildx / compose plugins from Docker's own apt repo (the
# base image's Ubuntu repos do not carry them); everything else is a normal
# Ubuntu package. gosu drops back to the unprivileged runner user in the
# entrypoint without the signal-handling problems `su`/`sudo` have as PID 1's
# child.
# build-essential/pkg-config/libssl-dev/libpq-dev: GitHub-hosted
# ubuntu-latest ships these by default; this custom image does not, and
# lint/test jobs that run bare (no `container:`) need `cc` to compile any
# crate at all (openssl-sys/libpq-sys need the -dev headers too) -- missing
# them fails every cargo fmt/clippy/test job the moment a repo migrates off
# ubuntu-latest.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        jq \
        git \
        unzip \
        zip \
        sudo \
        gosu \
        build-essential \
        pkg-config \
        libssl-dev \
        libpq-dev \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Preinstalled, version-pinned and sha256-verified CLI tools that CI jobs
# otherwise download on every run (an outbound fetch from a busy box has
# stalled deploy jobs for 8-13 minutes). linux/amd64 only, like the base
# image tag above. To bump: change the ARG pair, build, and update the
# matching pin in .github/actions/evergreen-ssh/action.yml (cloudflared) so
# the action keeps recognising the preinstalled binary.
#   - cloudflared: the ProxyCommand the evergreen-ssh action uses; the action
#     skips its own download when `cloudflared --version` already matches.
#   - trivy: for Trivy scan steps that call the binary directly instead of
#     letting a setup action restore it through the (slow) Actions cache.
ARG CLOUDFLARED_VERSION=2026.7.3
ARG CLOUDFLARED_SHA256=9d71c677db00134c1bd4144b7783486b654ad281b1ea62b4972098d19f770f17
ARG TRIVY_VERSION=0.74.0
ARG TRIVY_SHA256=2ae6fe3ee734b7fdf11335663e18c75ea12dccc76062f09f164a3b0f8be4371a
RUN set -eux; \
    curl -fsSL --retry 3 --max-time 300 -o /tmp/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64"; \
    echo "${CLOUDFLARED_SHA256}  /tmp/cloudflared" | sha256sum -c -; \
    install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared; \
    curl -fsSL --retry 3 --max-time 300 -o /tmp/trivy.tgz \
        "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"; \
    echo "${TRIVY_SHA256}  /tmp/trivy.tgz" | sha256sum -c -; \
    tar -xzf /tmp/trivy.tgz -C /usr/local/bin trivy; \
    rm -f /tmp/cloudflared /tmp/trivy.tgz; \
    cloudflared --version; \
    trivy --version

# Same trust model as a GitHub-hosted runner: the job user can sudo freely
# inside its own container, via the base image's own `%sudo` rule (it does
# `echo "%sudo ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers`, which TRUNCATES
# /etc/sudoers and drops the `@includedir /etc/sudoers.d` line — so anything
# written to /etc/sudoers.d/* here would never be parsed) plus `runner`
# already being in the `sudo` group in the base image. No sudoers file needed
# from this Dockerfile. Docker socket access (added by the caller via
# `group_add` at run time, not here — this image has no hostnames or
# tenant-specific group IDs baked in, and entrypoint.sh maps the socket's
# group into `runner`'s supplementary groups at start time) is the real
# privilege boundary.

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Stays root: the entrypoint fixes up ownership of bind-mounted volumes
# (which land root-owned from the host) before gosu-ing down to `runner`.
ENTRYPOINT ["/entrypoint.sh"]
