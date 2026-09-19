#!/usr/bin/env bash
# Generic self-hosted runner entrypoint. Runs as root (the image's default
# USER is overridden in the Dockerfile) so it can fix ownership on
# bind-mounted volumes, then drops to the unprivileged `runner` user for
# everything that touches GitHub or runs a job.
#
# All estate-specific values (org URL, runner group, labels, work dir, tool
# cache) arrive as env vars from the compose file that starts this container
# — nothing org-specific is baked in here. See README.md for the full list.
set -euo pipefail

RUNNER_HOME="/runner"
# Where the base image ships its runner install (config.sh, run.sh, bin/, …).
BASE_RUNNER_INSTALL="/home/runner"

# First start on a fresh volume: RUNNER_HOME is empty, so seed it from the
# image's own copy rather than re-downloading anything. Later starts (image
# rebuilt, container recreated) find config.sh already there and skip this —
# that's what makes the volume the thing that persists a runner's identity
# and self-update state across image bumps.
if [ ! -f "${RUNNER_HOME}/config.sh" ]; then
  echo "entrypoint: seeding ${RUNNER_HOME} from ${BASE_RUNNER_INSTALL}"
  mkdir -p "${RUNNER_HOME}"
  cp -a "${BASE_RUNNER_INSTALL}/." "${RUNNER_HOME}/"
fi

# Volumes are bind-mounted from the host and land root-owned; the runner
# process (and config.sh/run.sh) must own them to work at all.
chown -R runner:runner "${RUNNER_HOME}"
if [ -n "${RUNNER_TOOL_CACHE:-}" ]; then
  export RUNNER_TOOL_CACHE
  mkdir -p "${RUNNER_TOOL_CACHE}"
  chown -R runner:runner "${RUNNER_TOOL_CACHE}"
fi

cd "${RUNNER_HOME}"

# A runner that already registered (.runner exists) just needs to run — never
# re-register an already-configured identity, and never touch a leftover
# token file at that point.
if [ ! -f "${RUNNER_HOME}/.runner" ]; then
  TOKEN_FILE="${RUNNER_HOME}/registration-token"
  if [ ! -f "${TOKEN_FILE}" ]; then
    echo "entrypoint: not configured and no ${TOKEN_FILE} — cannot register. Mint a registration token and write it to that path (0600) before starting this container." >&2
    exit 1
  fi

  # `gosu` (via gosu's internal setup-user, which mirrors `su`) sets the
  # target user's supplementary groups from the container's own /etc/group,
  # NOT from whatever `group_add` the compose file passed to the container at
  # `docker run` time — a group injected only at the container/cgroup level is
  # invisible to it. So a docker-socket GID handed in via `group_add` never
  # reaches the `runner` process unless `runner` is also a member of a group
  # with that GID in /etc/group. Ensure that membership right before each
  # gosu call — generically, no GID baked in, so this stays org-agnostic:
  # look up (or create) the group that owns the mounted socket and add
  # `runner` to it.
  if [ -S /var/run/docker.sock ]; then
    SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
    GRP="$(getent group "${SOCK_GID}" | cut -d: -f1)"
    if [ -z "${GRP}" ]; then
      GRP=dockerhost
      groupadd -g "${SOCK_GID}" "${GRP}"
    fi
    usermod -aG "${GRP}" runner
  fi

  gosu runner ./config.sh --unattended \
    --url "${RUNNER_URL}" \
    --token "$(cat "${TOKEN_FILE}")" \
    --name "${RUNNER_NAME}" \
    --runnergroup "${RUNNER_GROUP}" \
    --labels "${RUNNER_LABELS}" \
    --work "${RUNNER_WORKDIR}" \
    --replace

  # One-shot credential — remove it the moment config.sh has consumed it, so
  # a restart never re-reads (or re-registers with) a stale token. A failed
  # config.sh exits the script first (set -e) and leaves the file for
  # inspection; clean it up by hand before retrying.
  rm -f "${TOKEN_FILE}"
fi

# run.sh's own loop handles self-update between jobs; nothing here disables
# that (no --disableupdate was passed above either).
#
# Re-run the same docker-socket group fixup here: this branch is also reached
# on every restart of an ALREADY-configured runner (the `if [ ! -f .runner ]`
# block above is skipped then), so `runner`'s supplementary groups must be
# ensured on this path too, not only right before the one-time config.sh call.
if [ -S /var/run/docker.sock ]; then
  SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
  GRP="$(getent group "${SOCK_GID}" | cut -d: -f1)"
  if [ -z "${GRP}" ]; then
    GRP=dockerhost
    groupadd -g "${SOCK_GID}" "${GRP}"
  fi
  usermod -aG "${GRP}" runner
fi

exec gosu runner ./run.sh
