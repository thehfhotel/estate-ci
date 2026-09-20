#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED script — runs after every job, inside the
# runner container, as the container's runner user. Persistent runners (see
# "Persistent, not ephemeral" in runner/README.md) reuse the same work
# directory across jobs; a job that does a sparse (or otherwise narrowed)
# checkout leaves that narrowed tree behind for the NEXT job of the same repo
# on the same runner, which then sees "no package.json / no Dockerfile" and
# fails for a reason that has nothing to do with its own change. Wiping
# GITHUB_WORKSPACE here after every job removes that inherited state so each
# job starts from a clean checkout again.
#
# Wire it up by mounting this file (or the whole runner/hooks directory) into
# the container and pointing ACTIONS_RUNNER_HOOK_JOB_COMPLETED at its
# in-container path — see runner/README.md.
#
# Some job steps run containerized as root (e.g. `docker run
# mcr.microsoft.com/playwright ...` mounting the workspace, or a
# `container: semgrep/semgrep` job) and leave root-owned files behind. This
# hook runs as the unprivileged runner user, so a plain `rm -rf` on those
# files silently no-ops (`|| true` swallows the Permission denied), leaving
# the leftover tree for the next job's checkout to choke on. If the runner
# container has a docker socket mounted in (see "Docker access" in
# runner/README.md), the wipe below runs as root inside a throwaway sibling
# container instead, so it can delete anything a previous root-run step
# created. Falls back to a plain `rm -rf` if docker isn't available. The
# image is configurable via HOOK_WIPE_IMAGE (default alpine:3.20) — pin it
# and pre-pull it on your box so the hook never blocks on an image pull.
#
# Persistent runners also keep the SAME $HOME across jobs, so any credential
# a job wrote there — a deploy SSH private key under ~/.ssh, a `docker login`
# token in ~/.docker/config.json, `gh auth login` state, a git credential
# helper file, a cloud CLI config — would otherwise sit there for the NEXT
# job on this runner to read. Sweep the well-known locations unconditionally
# after every job too, regardless of workflow content.
#
# Must NEVER fail the job: always exit 0, regardless of what happens above.
set -u

# Safety guard before the rm -rf below: only ever wipe GITHUB_WORKSPACE when
# it falls under RUNNER_WORK_PREFIX. Set RUNNER_WORK_PREFIX yourself (e.g. to
# the host-path prefix shared by every RUNNER_WORKDIR on your box) to pin
# this guard to a real, known work root — useful when several runners or
# repos share one host. Left unset, it defaults to the directory two levels
# above GITHUB_WORKSPACE itself: a job's GITHUB_WORKSPACE is normally
# "<work-dir>/<repo>/<repo>", so two levels up recovers <work-dir>. That
# default makes the guard trivially satisfied on an ordinary single-purpose
# runner (GITHUB_WORKSPACE can only ever be under its own parent), while
# still keeping the rm scoped to a work directory rather than trusting
# whatever GITHUB_WORKSPACE happens to hold, verbatim, with no check at all.
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  RUNNER_WORK_PREFIX="${RUNNER_WORK_PREFIX:-$(dirname -- "$(dirname -- "$GITHUB_WORKSPACE")")}"
else
  RUNNER_WORK_PREFIX="${RUNNER_WORK_PREFIX:-}"
fi

HOOK_WIPE_IMAGE="${HOOK_WIPE_IMAGE:-alpine:3.20}"

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -n "${RUNNER_WORK_PREFIX}" ] && [ "${GITHUB_WORKSPACE#"$RUNNER_WORK_PREFIX"}" != "$GITHUB_WORKSPACE" ]; then
  wipe_outcome=""
  if command -v docker >/dev/null 2>&1; then
    if docker run --rm -v "${GITHUB_WORKSPACE}:/w" "$HOOK_WIPE_IMAGE" \
         sh -c 'rm -rf -- /w/* /w/.[!.]* 2>/dev/null; true' >/dev/null 2>&1
    then
      wipe_outcome="docker-wipe ok"
    else
      # docker is present but the containerized wipe itself failed (e.g.
      # image pull blocked) — still attempt a plain rm as best effort.
      rm -rf -- "${GITHUB_WORKSPACE}"/* "${GITHUB_WORKSPACE}"/.[!.]* 2>/dev/null || true
      wipe_outcome="fallback (docker wipe failed)"
    fi
  else
    rm -rf -- "${GITHUB_WORKSPACE}"/* "${GITHUB_WORKSPACE}"/.[!.]* 2>/dev/null || true
    wipe_outcome="fallback (docker unavailable)"
  fi
  echo "job-completed hook: cleared GITHUB_WORKSPACE ${GITHUB_WORKSPACE} (${wipe_outcome})"
else
  echo "job-completed hook: GITHUB_WORKSPACE (${GITHUB_WORKSPACE:-unset}) not under RUNNER_WORK_PREFIX (${RUNNER_WORK_PREFIX:-unset}) — skipped"
fi

secret_removed_count=0

if [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; then
  # Whole ~/.ssh contents, not just a private key file — known_hosts is
  # re-created by whichever job next needs one, so nothing under here is
  # worth keeping between jobs.
  if [ -d "${HOME}/.ssh" ] && [ -n "$(ls -A "${HOME}/.ssh" 2>/dev/null)" ]; then
    rm -rf -- "${HOME}/.ssh"/* "${HOME}/.ssh"/.[!.]* 2>/dev/null || true
    secret_removed_count=$((secret_removed_count + 1))
  fi

  for p in \
    "${HOME}/.docker/config.json" \
    "${HOME}/.config/gh" \
    "${HOME}/.netrc" \
    "${HOME}/.git-credentials" \
    "${HOME}/.aws" \
    "${HOME}/.kube"
  do
    if [ -e "$p" ]; then
      rm -rf -- "$p" 2>/dev/null || true
      secret_removed_count=$((secret_removed_count + 1))
    fi
  done
fi

echo "job-completed hook: removed ${secret_removed_count} secret path(s) from HOME (${HOME:-unset})"

exit 0
