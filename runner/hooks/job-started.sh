#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED script: runs before every job, inside the
# runner container. It appends one "started" row to the jobs file (see
# job-row.sh for the row shape and the knobs). The job-completed hook appends
# the matching "completed" row.
#
# Wire it next to the completed hook (see "Job rows" in runner/README.md):
#   ACTIONS_RUNNER_HOOK_JOB_STARTED: <hooks dir in the container>/job-started.sh
# The hooks directory must be mounted whole, because this script sources
# job-row.sh from its own directory.
#
# Inside the runner container it must NEVER fail or delay the job: no network,
# no `set -e`, always exit 0. Never execute it on a workstation or the host shell.

# Same guard as job-completed.sh: only inside the CI runner container.
if [ "${HF_CI_RUNNER_CONTAINER:-}" != "1" ] || [ ! -e /.dockerenv ]; then
  echo "job-started hook: refusing to run outside the CI runner container (HF_CI_RUNNER_CONTAINER/.dockerenv missing)" >&2
  exit 2
fi

set +e
_hf_hooks_dir="${HF_CI_HOOKS_DIR:-$(dirname -- "${BASH_SOURCE[0]:-$0}")}"
if [ -r "$_hf_hooks_dir/job-row.sh" ]; then
  # shellcheck source=job-row.sh
  . "$_hf_hooks_dir/job-row.sh" && hf_job_row started
fi
exit 0
