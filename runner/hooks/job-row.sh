#!/usr/bin/env bash
# Shared helper for job-started.sh and job-completed.sh: append ONE JSON line per
# hook call to a CI-owned jobs file, so every job leaves a "started" row and a
# "completed" row. Sourced, never executed. Defines hf_job_row only.
#
#   HF_CI_CACHE       cache root; unset = rows disabled
#   HF_CI_JOB_ROWS=0  kill switch
#   HF_CI_JOBS_DIR    default $HF_CI_CACHE/shared/jobs; one file per UTC month,
#                     jobs-YYYY-MM.jsonl, appended with `>>` under flock
#
# Row shape (v=1). Every key is always present; unknown values are JSON null:
#   v, phase ("started" | "completed"), repo, workflow, job, run_id, run_attempt,
#   runner, lane, head_sha, event, ref, queued_at, started_at, finished_at,
#   conclusion
# - run_id / run_attempt are strings (a run id can exceed JS-safe integers).
# - workflow is the workflow NAME and job is the job ID (GITHUB_JOB); a job's
#   display name is not in the hook environment.
# - lane is the runner's own label list (RUNNER_LABELS), comma-separated.
# - head_sha is GITHUB_SHA: for pull_request events that is the merge commit,
#   not the PR head. Pair it with event/ref when attributing.
# - Timestamps are UTC ISO 8601 with milliseconds. The started row carries
#   started_at; the completed row carries finished_at and, when the matching
#   started hook ran on this runner, the same started_at.
# - queued_at and conclusion are NOT in the hook environment, so they are
#   always null here. The loader (plan item D1) fills them from the GitHub API
#   by run_id, and joins the two rows of a job on (runner, started_at).
#
# The helper must never fail or slow a job: it makes no network calls, takes
# the lock for at most 2 s, and swallows every error.

# True when $1 has any byte outside printable ASCII (checked in the C locale).
hf_job_nonascii() {
  local LC_ALL=C
  case $1 in *[!' '-~]*) return 0;; esac
  return 1
}

hf_job_json_str() {
  local s=$1
  if [ -z "$s" ]; then printf 'null'; return 0; fi
  # Invalid UTF-8 would make the whole line invalid JSON: drop such bytes.
  if hf_job_nonascii "$s" && command -v iconv >/dev/null 2>&1; then
    s=$(printf '%s' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
    if [ -z "$s" ]; then printf 'null'; return 0; fi
  fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//[$'\001'-$'\037']/ }
  printf '"%s"' "$s"
}

# $1 = started | completed
hf_job_row() {
  local phase=$1 dir file now active prev started="" finished="" row key
  [ -n "${HF_CI_CACHE:-}" ] || return 0
  [ "${HF_CI_JOB_ROWS:-1}" = "0" ] && return 0
  dir="${HF_CI_JOBS_DIR:-$HF_CI_CACHE/shared/jobs}"
  mkdir -p "$dir" 2>/dev/null || return 0
  now=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null) || return 0
  file="$dir/jobs-${now:0:7}.jsonl"
  active="$dir/.active-${RUNNER_NAME:-unknown}"
  key="${GITHUB_RUN_ID:-}/${GITHUB_RUN_ATTEMPT:-}/${GITHUB_JOB:-}"
  case "$phase" in
    started)
      started=$now
      printf '%s %s\n' "$key" "$started" > "$active" 2>/dev/null
      ;;
    completed)
      finished=$now
      # Pair with the started hook of the same job on this runner, if any.
      if [ -r "$active" ]; then
        prev=$(head -n1 "$active" 2>/dev/null)
        [ "${prev%% *}" = "$key" ] && started=${prev#* }
        rm -f "$active" 2>/dev/null
      fi
      ;;
    *) return 0 ;;
  esac
  row="{\"v\":1,\"phase\":\"${phase}\""
  row="$row,\"repo\":$(hf_job_json_str "${GITHUB_REPOSITORY:-}")"
  row="$row,\"workflow\":$(hf_job_json_str "${GITHUB_WORKFLOW:-}")"
  row="$row,\"job\":$(hf_job_json_str "${GITHUB_JOB:-}")"
  row="$row,\"run_id\":$(hf_job_json_str "${GITHUB_RUN_ID:-}")"
  row="$row,\"run_attempt\":$(hf_job_json_str "${GITHUB_RUN_ATTEMPT:-}")"
  row="$row,\"runner\":$(hf_job_json_str "${RUNNER_NAME:-}")"
  row="$row,\"lane\":$(hf_job_json_str "${RUNNER_LABELS:-}")"
  row="$row,\"head_sha\":$(hf_job_json_str "${GITHUB_SHA:-}")"
  row="$row,\"event\":$(hf_job_json_str "${GITHUB_EVENT_NAME:-}")"
  row="$row,\"ref\":$(hf_job_json_str "${GITHUB_REF:-}")"
  row="$row,\"queued_at\":null"
  row="$row,\"started_at\":$(hf_job_json_str "$started")"
  row="$row,\"finished_at\":$(hf_job_json_str "$finished")"
  row="$row,\"conclusion\":null}"
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 2 9 && printf '%s\n' "$row" >&9 ) 2>/dev/null 9>>"$file"
  else
    printf '%s\n' "$row" >> "$file" 2>/dev/null
  fi
  return 0
}
