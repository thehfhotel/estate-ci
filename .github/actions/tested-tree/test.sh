#!/usr/bin/env bash
# Local test for tested-tree.sh: a throwaway git repo, a cache dir, and a mock
# GitHub API (python3 http.server over canned JSON files).
# No CI runs this repo's tests; run it by hand after touching tested-tree.sh:
#   bash .github/actions/tested-tree/test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
srv_pid=""
cleanup() {
  [[ -n "$srv_pid" ]] && kill "$srv_pid" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
fails=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

REPO="acme/widgets"
CACHE="$TMP/cache"
repo="$TMP/repo"
git init -q "$repo"
echo one >"$repo/a"
git -C "$repo" add a
git -C "$repo" commit -q -m one
TREE="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
MERGE="$(git -C "$repo" rev-parse HEAD)"
OTHER_TREE="1111111111111111111111111111111111111111"
MARKER_DIR="$CACHE/shared/tested-trees/acme__widgets"

# Mock API: files under $TMP/api are served at the same URL path.
API_DIR="$TMP/api"
mkdir -p "$API_DIR"
PORT="$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
(cd "$API_DIR" && exec /usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
srv_pid=$!
for _ in $(seq 1 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  sleep 0.1
done

HEAD_SHA="2222222222222222222222222222222222222222"   # the PR head the run tested
set_run() { # set_run <id> <attempt> <event> <status> <conclusion> [repo] [head_sha] [head_repo]
  mkdir -p "$API_DIR/repos/$REPO/actions/runs/$1/attempts"
  cat >"$API_DIR/repos/$REPO/actions/runs/$1/attempts/$2" <<J
{"id": $1, "run_attempt": $2, "event": "$3", "status": "$4", "conclusion": "$5", "head_sha": "${7:-$HEAD_SHA}", "repository": {"full_name": "${6:-$REPO}"}, "head_repository": {"full_name": "${8:-$REPO}"}}
J
}
set_commit() { # set_commit <sha> <tree> [parent head sha]
  mkdir -p "$API_DIR/repos/$REPO/git/commits"
  echo "{\"sha\": \"$1\", \"tree\": {\"sha\": \"$2\"}, \"parents\": [{\"sha\": \"3333333333333333333333333333333333333333\"}, {\"sha\": \"${3:-$HEAD_SHA}\"}]}" >"$API_DIR/repos/$REPO/git/commits/$1"
}
write_marker() { # write_marker <json>
  mkdir -p "$MARKER_DIR"
  printf '%s' "$1" >"$MARKER_DIR/$TREE"
}
good_marker() {
  write_marker "{\"run_id\": 100, \"run_attempt\": 1, \"repository\": \"$REPO\", \"merge_commit_sha\": \"$MERGE\", \"tree_sha\": \"$TREE\"}"
}
reset() {
  rm -rf "$MARKER_DIR" "$API_DIR/repos"
}

run() { # run <extra env...> : runs the script in the repo, sets $OUT_TEXT
  (cd "$repo" && env -i PATH="$PATH" HOME="$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GITHUB_OUTPUT="$TMP/out" GITHUB_REPOSITORY="$REPO" GITHUB_API_URL="http://127.0.0.1:$PORT" \
    TT_TOKEN=t HF_CI_CACHE="$CACHE" "$@" bash "$HERE/tested-tree.sh" >"$TMP/log" 2>&1)
  OUT_TEXT="$(cat "$TMP/out" 2>/dev/null)"
  rm -f "$TMP/out"
}

expect() { # expect <name> <needle>...
  local name="$1" n
  shift
  for n in "$@"; do
    if [[ "$OUT_TEXT" != *"$n"* ]]; then
      echo "FAIL: $name: missing '$n'"
      echo "--- output"
      echo "$OUT_TEXT"
      echo "--- log"
      cat "$TMP/log"
      fails=$((fails + 1))
      return
    fi
  done
  echo "ok:   $name"
}

PR=(TT_MODE=record GITHUB_EVENT_NAME=pull_request TT_HEAD_REPO="$REPO" GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$MERGE")
PUSH=(TT_MODE=check GITHUB_EVENT_NAME=push)

# ---- record
reset
run "${PR[@]}"
expect "record writes a marker" "result=recorded"
if [[ "$(jq -r '[.run_id,.run_attempt,.repository,.merge_commit_sha,.tree_sha]|join(" ")' "$MARKER_DIR/$TREE" 2>/dev/null)" == "100 1 $REPO $MERGE $TREE" ]]; then
  echo "ok:   marker content"
else
  echo "FAIL: marker content: $(cat "$MARKER_DIR/$TREE" 2>&1)"
  fails=$((fails + 1))
fi
ls "$MARKER_DIR"/.tmp.* >/dev/null 2>&1 && {
  echo "FAIL: temp file left behind"
  fails=$((fails + 1))
}

reset
run "${PR[@]}" HF_CI_CACHE=
expect "record no-ops without HF_CI_CACHE" "result=noop"
[[ -e "$MARKER_DIR" ]] || echo "ok:   nothing written without HF_CI_CACHE"

reset
run "${PR[@]}" GITHUB_EVENT_NAME=push
expect "record no-ops off pull_request" "result=noop"
reset
run "${PR[@]}" TT_HEAD_REPO=evil/widgets
expect "record no-ops for a fork PR" "result=noop"
[[ -e "$MARKER_DIR" ]] || echo "ok:   nothing written for a fork PR"

# ---- check: the one path that skips
reset
good_marker
set_run 100 1 pull_request completed success
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "check skips on a verified marker" "result=skip-tests" "skip=true" "run 100"

# ---- check: everything else is full
reset
run "${PUSH[@]}"
expect "no marker" "result=full" "no marker"

reset
good_marker
set_run 100 1 pull_request completed success
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}" HF_CI_CACHE=
expect "HF_CI_CACHE unset" "result=full" "HF_CI_CACHE"
run "${PUSH[@]}" GITHUB_EVENT_NAME=pull_request
expect "not a push" "result=full"
run "${PUSH[@]}" TT_TOKEN=
expect "no token" "result=full"

reset
write_marker "not json {"
run "${PUSH[@]}"
expect "unparsable marker" "result=full" "unparsable"

reset
write_marker "{\"run_id\": \"x\", \"run_attempt\": 1, \"repository\": \"$REPO\", \"merge_commit_sha\": \"$MERGE\", \"tree_sha\": \"$TREE\"}"
run "${PUSH[@]}"
expect "malformed field" "result=full"

reset
write_marker "{\"run_id\": 100, \"run_attempt\": 1, \"repository\": \"other/repo\", \"merge_commit_sha\": \"$MERGE\", \"tree_sha\": \"$TREE\"}"
run "${PUSH[@]}"
expect "marker names another repository" "result=full" "other/repo"

reset
write_marker "{\"run_id\": 100, \"run_attempt\": 1, \"repository\": \"$REPO\", \"merge_commit_sha\": \"$MERGE\", \"tree_sha\": \"$OTHER_TREE\"}"
run "${PUSH[@]}"
expect "marker tree differs from its file name" "result=full"

reset
good_marker
run "${PUSH[@]}"
expect "API 404 for the run" "result=full" "API error"

for case in "push completed success" "pull_request completed failure" "pull_request in_progress null" "pull_request completed cancelled"; do
  read -r ev st co <<<"$case"
  reset
  good_marker
  set_run 100 1 "$ev" "$st" "$co"
  set_commit "$MERGE" "$TREE"
  run "${PUSH[@]}"
  expect "run $ev/$st/$co is rejected" "result=full" "rejected"
done

reset
good_marker
set_run 100 1 pull_request completed success "someone/else"
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "run from another repository" "result=full" "another repository"

reset
good_marker
set_run 100 1 pull_request completed success
run "${PUSH[@]}"
expect "API 404 for the merge commit" "result=full" "API error"

reset
good_marker
set_run 100 1 pull_request completed success
set_commit "$MERGE" "$OTHER_TREE"
run "${PUSH[@]}"
expect "merge commit has a different tree" "result=full" "has tree"

# the run is not tied to the merge commit (the review's bypass): green run, matching tree, wrong pair
reset
good_marker
set_run 100 1 pull_request completed success "" "4444444444444444444444444444444444444444"
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "run head_sha not among the merge commit's parents" "result=full" "did not produce"

reset
good_marker
set_run 100 1 pull_request completed success
set_commit "$MERGE" "$TREE" "5555555555555555555555555555555555555555"
run "${PUSH[@]}"
expect "merge commit parented on another head" "result=full" "did not produce"

reset
good_marker
set_run 100 1 pull_request completed success "" "$HEAD_SHA" "evil/widgets"
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "run from a fork head repository" "result=full" "fork"

# attempts: the recorded attempt is what counts
reset
good_marker
set_run 100 1 pull_request completed failure
set_run 100 2 pull_request completed success
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "recorded attempt 1 was red (attempt 2 green) is rejected" "result=full" "rejected"

reset
write_marker "{\"run_id\": 100, \"run_attempt\": 2, \"repository\": \"$REPO\", \"merge_commit_sha\": \"$MERGE\", \"tree_sha\": \"$TREE\"}"
set_run 100 2 pull_request completed success
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "recorded attempt 2 green passes" "result=skip-tests"

reset
good_marker
mkdir -p "$API_DIR/repos/$REPO/actions/runs/100/attempts"
cat >"$API_DIR/repos/$REPO/actions/runs/100/attempts/1" <<J
{"id": 100, "run_attempt": 7, "event": "pull_request", "status": "completed", "conclusion": "success", "head_sha": "$HEAD_SHA", "repository": {"full_name": "$REPO"}, "head_repository": {"full_name": "$REPO"}}
J
set_commit "$MERGE" "$TREE"
run "${PUSH[@]}"
expect "attempt number in the response must match" "result=full" "attempt mismatch"

# record: HEAD must be the merge commit
reset
git -C "$repo" commit -q --allow-empty -m other
run "${PR[@]}"
expect "record no-ops when HEAD is not GITHUB_SHA" "result=noop" "not the merge commit"
git -C "$repo" reset -q --hard "$MERGE"

# the token never appears on a command line
reset
good_marker
set_run 100 1 pull_request completed success
set_commit "$MERGE" "$TREE"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/argv"\nexec /usr/bin/curl "$@"\n' "$TMP" >"$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
run "${PUSH[@]}" TT_TOKEN=sekrit-token PATH="$TMP/bin:$PATH"
expect "still skips through a wrapped curl" "result=skip-tests"
if [[ -s "$TMP/argv" ]] && ! grep -q sekrit-token "$TMP/argv"; then ok_msg="ok:   token is not in curl's argv"; echo "$ok_msg"; else echo "FAIL: token in curl argv (or wrapper unused)"; fails=$((fails + 1)); fi
rm -f "$TMP/bin/curl"

run TT_MODE=bogus
if [[ "$(cat "$TMP/log")" == *"mode must be"* ]]; then
  echo "ok:   bad mode is an error"
else
  echo "FAIL: bad mode"
  fails=$((fails + 1))
fi

if [[ $fails -gt 0 ]]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all passed"
