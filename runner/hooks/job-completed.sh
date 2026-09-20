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

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -n "${RUNNER_WORK_PREFIX}" ] && [ "${GITHUB_WORKSPACE#"$RUNNER_WORK_PREFIX"}" != "$GITHUB_WORKSPACE" ]; then
  rm -rf -- "${GITHUB_WORKSPACE}"/* "${GITHUB_WORKSPACE}"/.[!.]* 2>/dev/null || true
  echo "job-completed hook: cleared GITHUB_WORKSPACE ${GITHUB_WORKSPACE}"
else
  echo "job-completed hook: GITHUB_WORKSPACE (${GITHUB_WORKSPACE:-unset}) not under RUNNER_WORK_PREFIX (${RUNNER_WORK_PREFIX:-unset}) — skipped"
fi

exit 0
