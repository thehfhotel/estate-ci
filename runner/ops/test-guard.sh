#!/usr/bin/env bash
# Regression test for the guard in hooks/job-completed.sh and hooks/job-started.sh:
# outside the CI runner container (no HF_CI_RUNNER_CONTAINER=1) they must refuse,
# exit 2 and leave EVERYTHING alone (no credential sweep, no workspace wipe, no
# row, no prune); inside it (marker set) they must do their normal work.
#
# Run it ONLY inside a throwaway container, without the Docker socket:
#   docker run --rm --entrypoint bash -v "$PWD/runner:/r:ro" <runner-image> /r/ops/test-guard.sh
# It refuses to run anywhere else. It never touches the real HOME: every hook
# call gets a fake HOME made with mktemp, holding dummy credential files.
# Exits non-zero when a check fails.
set -u

[ -e /.dockerenv ] || { echo "test-guard: refusing to run outside a container (/.dockerenv missing)" >&2; exit 2; }
[ ! -e /var/run/docker.sock ] || { echo "test-guard: refusing to run with the Docker socket mounted (the hook would start sibling containers)" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS=$HERE/../hooks
T=$(mktemp -d /tmp/guardtest.XXXXXX) || exit 2
case "$T" in /tmp/guardtest.*) ;; *) echo "test-guard: unexpected temp dir $T" >&2; exit 2;; esac
# This script's own HOME is a temp dir too, so nothing below can reach a real one.
export HOME=$T/script-home
mkdir -p "$HOME"
trap 'rm -rf "$T"' EXIT

fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { # description, test command...
  local d=$1; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# A fresh sandbox: fake HOME with dummy credentials, a fake workspace, a cache root.
sandbox() {
  S=$T/$1
  mkdir -p "$S/home/.ssh" "$S/home/.config/gh" "$S/work/repo/repo" "$S/cache/shared"
  echo key > "$S/home/.ssh/x"; echo tok > "$S/home/.config/gh/hosts.yml"; echo n > "$S/home/.netrc"
  echo keep > "$S/work/repo/repo/keepme"
}

# Run a hook the way the runner does (bash -e), from a clean environment:
# $1 script, $2 marker value or "unset"; stdout/stderr land in $S/out and $S/err.
run_hook() {
  local script=$1 marker=$2 mk=()
  [ "$marker" = unset ] || mk=( "HF_CI_RUNNER_CONTAINER=$marker" )
  env -i PATH="$PATH" HOME="$S/home" HF_CI_CACHE="$S/cache" GITHUB_WORKSPACE="$S/work/repo/repo" \
    RUNNER_NAME=guard-test RUNNER_LABELS=test GITHUB_REPOSITORY=org/repo GITHUB_WORKFLOW=CI GITHUB_JOB=j \
    GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=abc GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main \
    "${mk[@]}" bash -e "$HOOKS/$script" > "$S/out" 2> "$S/err"
  rc=$?
}

untouched() { # nothing of the sandbox was changed
  [ -f "$S/home/.ssh/x" ] && [ -f "$S/home/.config/gh/hosts.yml" ] && [ -f "$S/home/.netrc" ] \
    && [ -f "$S/work/repo/repo/keepme" ] && [ ! -e "$S/cache/shared/jobs" ] \
    && [ ! -e "$S/cache/prune.log" ] && [ ! -e "$S/cache/.prune-stamp" ]
}

echo "== refusal outside the runner container"
for script in job-completed.sh job-started.sh; do
  for marker in unset 0; do
    sandbox "refuse-${script%.sh}-$marker"
    run_hook "$script" "$marker"
    check "$script, marker $marker: exit 2" test "$rc" -eq 2
    check "$script, marker $marker: one stderr line saying refusing" grep -q "refusing to run outside the CI runner container" "$S/err"
    check "$script, marker $marker: nothing on stdout" test ! -s "$S/out"
    check "$script, marker $marker: credentials, workspace, rows, prune all untouched" untouched
  done
done

echo "== normal path inside the runner container (marker set, fake HOME)"
sandbox started
run_hook job-started.sh 1
check "job-started.sh: exit 0" test "$rc" -eq 0
check "job-started.sh: wrote a started row" grep -q '"phase":"started"' "$S"/cache/shared/jobs/jobs-*.jsonl
check "job-started.sh: left the fake credentials alone" test -f "$S/home/.ssh/x"

sandbox completed
run_hook job-completed.sh 1
check "job-completed.sh: exit 0" test "$rc" -eq 0
check "job-completed.sh: wrote a completed row" grep -q '"phase":"completed"' "$S"/cache/shared/jobs/jobs-*.jsonl
check "job-completed.sh: swept the fake ~/.ssh contents" test ! -e "$S/home/.ssh/x"
check "job-completed.sh: swept the fake ~/.config/gh" test ! -e "$S/home/.config/gh"
check "job-completed.sh: swept the fake ~/.netrc" test ! -e "$S/home/.netrc"
check "job-completed.sh: wiped the fake workspace" test ! -e "$S/work/repo/repo/keepme"
check "job-completed.sh: skipped the prune with a log line (no docker, never inline)" grep -q "prune skipped" "$S/out"
check "job-completed.sh: no prune ran inline" test ! -e "$S/cache/prune.log"

echo "FAIL=$fail"
exit "$fail"
