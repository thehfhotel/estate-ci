#!/usr/bin/env bash
# Local test for tested-tree.sh: a throwaway git repo, a cache dir, and a mock
# GitHub API (python3 http.server: canned JSON files for GET, recorded POSTs).
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
# GET serves files under $API_DIR (the query string is ignored); POST appends
# "<path> <authorization present?> <body>" to $TMP/posts and answers with the
# code in $TMP/post_code (default 201).
cat >"$TMP/mock.py" <<'PY'
import http.server, os, sys
TMP = sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        auth = "auth" if self.headers.get("Authorization", "").startswith("Bearer ") else "noauth"
        with open(os.path.join(TMP, "posts"), "a") as f:
            f.write("%s %s %s\n" % (self.path, auth, body))
        code = 201
        try: code = int(open(os.path.join(TMP, "post_code")).read().strip())
        except Exception: pass
        out = b'{"id": 1}' if code == 201 else b'{"message": "Resource not accessible by integration"}'
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
os.chdir(sys.argv[3])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
(exec /usr/bin/python3 "$TMP/mock.py" "$PORT" "$TMP" "$API_DIR" >/dev/null 2>&1) &
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
PR_HEAD_SHA="$HEAD_SHA"                                 # the PR head the status sits on
STATUS_CTX="estate-ci/tested-tree"
status_desc() { # status_desc <run> <attempt> <merge> <tree>
  echo "run=$1 attempt=$2 merge=$3 tree=$4"
}
# set_pulls <json array body> : what /commits/<HEAD>/pulls answers
set_pulls() {
  mkdir -p "$API_DIR/repos/$REPO/commits/$MERGE"
  printf '%s' "$1" >"$API_DIR/repos/$REPO/commits/$MERGE/pulls"
}
good_pulls() { # good_pulls [pr head sha]
  set_pulls "[{\"number\": 7, \"merged_at\": \"2026-01-01T00:00:00Z\", \"head\": {\"sha\": \"${1:-$PR_HEAD_SHA}\", \"repo\": {\"full_name\": \"$REPO\"}}, \"base\": {\"repo\": {\"full_name\": \"$REPO\"}}}]"
}
# set_statuses <head sha> <json array body>
set_statuses() {
  mkdir -p "$API_DIR/repos/$REPO/commits/$1"
  printf '%s' "$2" >"$API_DIR/repos/$REPO/commits/$1/statuses"
}
good_status() { # good_status [description] [context] [state] [id]
  echo "{\"id\": ${4:-10}, \"context\": \"${2:-$STATUS_CTX}\", \"state\": \"${3:-success}\", \"description\": \"${1:-$(status_desc 100 1 "$MERGE" "$TREE")}\"}"
}
status_world() { # a verified world with the proof only in the commit status (no marker)
  reset
  set_run 100 1 pull_request completed success
  set_commit "$MERGE" "$TREE"
  good_pulls
  set_statuses "$PR_HEAD_SHA" "[$(good_status)]"
}
reset() {
  rm -rf "$MARKER_DIR" "$API_DIR/repos" "$TMP/posts" "$TMP/post_code"
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

PR=(TT_MODE=record GITHUB_EVENT_NAME=pull_request TT_HEAD_REPO="$REPO" TT_HEAD_SHA="$PR_HEAD_SHA" GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$MERGE")
PUSH=(TT_MODE=check GITHUB_EVENT_NAME=push GITHUB_SHA="$MERGE")

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

# ---- record: the commit status
reset
run "${PR[@]}"
expect "record posts a commit status" "result=recorded" "commit status posted"
want_post="/repos/$REPO/statuses/$PR_HEAD_SHA auth"
if [[ "$(cut -d' ' -f1,2 "$TMP/posts" 2>/dev/null)" == "$want_post" ]] &&
  [[ "$(sed 's/^[^ ]* [^ ]* //' "$TMP/posts" | jq -r '[.state,.context,.description,.target_url]|join("|")')" == "success|$STATUS_CTX|$(status_desc 100 1 "$MERGE" "$TREE")|https://github.com/$REPO/actions/runs/100" ]]; then
  echo "ok:   status body and path"
else
  echo "FAIL: status body or path: $(cat "$TMP/posts" 2>&1)"
  fails=$((fails + 1))
fi
desc_len="$(sed 's/^[^ ]* [^ ]* //' "$TMP/posts" | jq -r '.description|length')"
if [[ "$desc_len" -le 140 ]]; then echo "ok:   status description is $desc_len chars (<= 140)"; else echo "FAIL: description $desc_len chars"; fails=$((fails + 1)); fi

reset
echo 403 >"$TMP/post_code"
run "${PR[@]}"
expect "record survives a refused status (no statuses: write)" "result=recorded" "commit status not posted (HTTP 403)"
[[ -f "$MARKER_DIR/$TREE" ]] && echo "ok:   local marker still written after a refused status" || { echo "FAIL: marker missing"; fails=$((fails + 1)); }
grep -q 'statuses: write' "$TMP/log" && echo "ok:   refusal is logged as a warning" || { echo "FAIL: no warning logged"; fails=$((fails + 1)); }

reset
run "${PR[@]}" TT_HEAD_SHA=
expect "record without a PR head sha still records" "result=recorded" "PR head sha unavailable"
[[ -e "$TMP/posts" ]] && { echo "FAIL: posted without a head sha"; fails=$((fails + 1)); } || echo "ok:   no POST without a head sha"

reset
run "${PR[@]}" TT_TOKEN=
expect "record without a token still records" "result=recorded" "no token"

reset
run "${PR[@]}" GITHUB_EVENT_NAME=push
[[ -e "$TMP/posts" ]] && { echo "FAIL: posted off pull_request"; fails=$((fails + 1)); } || echo "ok:   no POST off pull_request"
reset
run "${PR[@]}" TT_HEAD_REPO=evil/widgets
[[ -e "$TMP/posts" ]] && { echo "FAIL: posted for a fork PR"; fails=$((fails + 1)); } || echo "ok:   no POST for a fork PR"

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

# ---- check: no local marker, the commit status carries the proof
status_world
run "${PUSH[@]}"
expect "status path skips" "result=skip-tests" "skip=true" "PR #7" "run 100" "commit status"

# the local marker still wins when present (and is verified on its own)
status_world
good_marker
set_statuses "$PR_HEAD_SHA" "[]"
run "${PUSH[@]}"
expect "marker path unchanged when a marker exists" "result=skip-tests" "run 100"
[[ "$OUT_TEXT" != *"commit status"* ]] && echo "ok:   marker path did not consult statuses" || { echo "FAIL: used statuses"; fails=$((fails + 1)); }

# a bad local marker is NOT rescued by a good status (marker present = current path)
status_world
write_marker "not json {"
run "${PUSH[@]}"
expect "present-but-bad marker stays full" "result=full" "unparsable"

status_world
run "${PUSH[@]}" GITHUB_SHA=
expect "status path needs GITHUB_SHA" "result=full" "GITHUB_SHA"
status_world
run "${PUSH[@]}" GITHUB_SHA="6666666666666666666666666666666666666666"
expect "status path needs HEAD == GITHUB_SHA" "result=full" "not the pushed commit"

reset
run "${PUSH[@]}"
expect "no pulls answer" "result=full" "no marker" "pull-requests: read"

status_world
set_pulls "[]"
run "${PUSH[@]}"
expect "no PR for the commit" "result=full" "no merged same-repository pull request"

status_world
set_pulls "[{\"number\": 7, \"merged_at\": null, \"head\": {\"sha\": \"$PR_HEAD_SHA\", \"repo\": {\"full_name\": \"$REPO\"}}, \"base\": {\"repo\": {\"full_name\": \"$REPO\"}}}]"
run "${PUSH[@]}"
expect "unmerged PR is ignored" "result=full" "no merged same-repository pull request"

status_world
set_pulls "[{\"number\": 7, \"merged_at\": \"2026-01-01T00:00:00Z\", \"head\": {\"sha\": \"$PR_HEAD_SHA\", \"repo\": {\"full_name\": \"evil/widgets\"}}, \"base\": {\"repo\": {\"full_name\": \"$REPO\"}}}]"
run "${PUSH[@]}"
expect "fork PR is ignored" "result=full" "no merged same-repository pull request"

status_world
set_pulls "not json"
run "${PUSH[@]}"
expect "unparsable pulls answer" "result=full" "no merged same-repository pull request"

status_world
rm -rf "$API_DIR/repos/$REPO/commits/$PR_HEAD_SHA"
run "${PUSH[@]}"
expect "statuses 404 (no statuses: read)" "result=full" "statuses: read"

status_world
set_statuses "$PR_HEAD_SHA" "[]"
run "${PUSH[@]}"
expect "no tested-tree status" "result=full" "no $STATUS_CTX status"

status_world
set_statuses "$PR_HEAD_SHA" "[$(good_status "" "ci/other")]"
run "${PUSH[@]}"
expect "status with another context" "result=full" "no $STATUS_CTX status"

status_world
set_statuses "$PR_HEAD_SHA" "[$(good_status "" "" failure)]"
run "${PUSH[@]}"
expect "non-success status" "result=full" "no $STATUS_CTX status"

status_world
set_statuses "$PR_HEAD_SHA" "[$(good_status "$(status_desc 100 1 "$MERGE" "$OTHER_TREE")")]"
run "${PUSH[@]}"
expect "status for a different tree" "result=full" "no $STATUS_CTX status"

for bad in "run=x attempt=1 merge=$MERGE tree=$TREE" "run=100 attempt=1 merge=${MERGE:0:39} tree=$TREE" "run=100 attempt=1 merge=$MERGE tree=${TREE^^}" "run=100 attempt=1 merge=$MERGE tree=$TREE extra" "run=100 attempt=1 merge=$MERGE tree=$TREE\\nrun=1" "  run=100 attempt=1 merge=$MERGE tree=$TREE" "run=100 merge=$MERGE tree=$TREE"; do
  status_world
  set_statuses "$PR_HEAD_SHA" "[$(good_status "$bad")]"
  run "${PUSH[@]}"
  expect "malformed status description is ignored: ${bad:0:24}" "result=full" "no $STATUS_CTX status"
done

status_world
set_run 100 1 pull_request completed failure
run "${PUSH[@]}"
expect "status path: red run" "result=full" "rejected"

status_world
set_run 100 1 pull_request completed success "" "4444444444444444444444444444444444444444"
run "${PUSH[@]}"
expect "status path: run tested another head than the PR head" "result=full" "not the PR head"

status_world
set_commit "$MERGE" "$OTHER_TREE"
run "${PUSH[@]}"
expect "status path: merge commit has a different tree" "result=full" "has tree"

status_world
set_commit "$MERGE" "$TREE" "5555555555555555555555555555555555555555"
run "${PUSH[@]}"
expect "status path: merge commit not parented on the run head" "result=full" "did not produce"

status_world
set_run 100 1 pull_request completed success "" "$PR_HEAD_SHA" "evil/widgets"
run "${PUSH[@]}"
expect "status path: run from a fork head repository" "result=full" "fork"

status_world
rm -rf "$API_DIR/repos/$REPO/actions"
run "${PUSH[@]}"
expect "status path: run API error" "result=full" "API error"

# newest status first; an older, failing candidate does not block a newer good one
status_world
set_run 99 1 pull_request completed failure
set_statuses "$PR_HEAD_SHA" "[$(good_status "$(status_desc 99 1 "$MERGE" "$TREE")" "" success 5),$(good_status "" "" success 20)]"
run "${PUSH[@]}"
expect "newest status is tried first" "result=skip-tests" "run 100"

status_world
set_run 100 1 pull_request completed failure
set_run 99 1 pull_request completed success
set_statuses "$PR_HEAD_SHA" "[$(good_status "" "" success 20),$(good_status "$(status_desc 99 1 "$MERGE" "$TREE")" "" success 5)]"
run "${PUSH[@]}"
expect "a failing newest candidate falls through to an older verified one" "result=skip-tests" "run 99"

# second PR in the list (squash + later PR sharing the commit): cap is three PRs
status_world
OTHER_HEAD="7777777777777777777777777777777777777777"
set_pulls "[{\"number\": 6, \"merged_at\": \"2026-01-01T00:00:00Z\", \"head\": {\"sha\": \"$OTHER_HEAD\", \"repo\": {\"full_name\": \"$REPO\"}}, \"base\": {\"repo\": {\"full_name\": \"$REPO\"}}}, {\"number\": 7, \"merged_at\": \"2026-01-01T00:00:00Z\", \"head\": {\"sha\": \"$PR_HEAD_SHA\", \"repo\": {\"full_name\": \"$REPO\"}}, \"base\": {\"repo\": {\"full_name\": \"$REPO\"}}}]"
run "${PUSH[@]}"
expect "second PR in the list is consulted" "result=skip-tests" "PR #7"
status_world
set_pulls "$(jq -nc --arg o "$OTHER_HEAD" --arg h "$PR_HEAD_SHA" --arg r "$REPO" '
  def pr($n; $sha): {number: $n, merged_at: "2026-01-01T00:00:00Z", head: {sha: $sha, repo: {full_name: $r}}, base: {repo: {full_name: $r}}};
  [pr(1; $o), pr(2; $o), pr(3; $o), pr(7; $h)]')"
run "${PUSH[@]}"
expect "only the first three PRs are consulted" "result=full"

# pagination: 100 unrelated statuses on page 1, ours on page 2 (the mock ignores ?page, so
# the same body is served for every page: ours must still be found and capped at 3 pages)
status_world
set_statuses "$PR_HEAD_SHA" "[$(for i in $(seq 1 99); do printf '%s,' "$(good_status x ci/other success $i)"; done)$(good_status "" "" success 500)]"
run "${PUSH[@]}"
expect "a status found among 100 entries" "result=skip-tests"

# the token never appears on a command line, GET or POST
status_world
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/argv2"\nexec /usr/bin/curl "$@"\n' "$TMP" >"$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
run "${PUSH[@]}" TT_TOKEN=sekrit-token PATH="$TMP/bin:$PATH"
expect "status path through a wrapped curl" "result=skip-tests"
reset
run "${PR[@]}" TT_TOKEN=sekrit-token PATH="$TMP/bin:$PATH"
expect "record through a wrapped curl" "result=recorded" "commit status posted"
if [[ -s "$TMP/argv2" ]] && ! grep -q sekrit-token "$TMP/argv2" && grep -q POST "$TMP/argv2"; then echo "ok:   token is not in curl's argv (status GET and POST)"; else echo "FAIL: token in curl argv (or wrapper unused)"; fails=$((fails + 1)); fi
rm -f "$TMP/bin/curl"

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
