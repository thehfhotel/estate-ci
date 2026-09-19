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
exec gosu runner ./run.sh
