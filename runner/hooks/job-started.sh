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
# Must NEVER fail or delay the job: no network, no `set -e`, always exit 0.

set +e
_hf_hooks_dir="${HF_CI_HOOKS_DIR:-$(dirname -- "${BASH_SOURCE[0]:-$0}")}"
if [ -r "$_hf_hooks_dir/job-row.sh" ]; then
  # shellcheck source=job-row.sh
  . "$_hf_hooks_dir/job-row.sh" && hf_job_row started
fi
exit 0
