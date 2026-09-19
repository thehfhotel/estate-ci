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
