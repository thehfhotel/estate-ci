#!/usr/bin/env bash
# tested-tree.sh: record / check a "this exact tree was tested" marker.
# See README.md in this directory for the contract and the threat model.
#
# Not `set -e`: `record` is best effort and must never fail a green PR run,
# and `check` must fail CLOSED (output `full`) on anything unexpected.
set -uo pipefail

MODE="${TT_MODE:-}"
TOKEN="${TT_TOKEN:-}"
CACHE="${HF_CI_CACHE:-}"
REPO="${GITHUB_REPOSITORY:-}"
EVENT="${GITHUB_EVENT_NAME:-}"
API="${GITHUB_API_URL:-https://api.github.com}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# finish <result> <reason>: one outputs block, one log line, then exit 0.
finish() {
  local result="$1" reason="$2" skip=false
  [[ "$result" == skip-tests ]] && skip=true
  {
    echo "result=$result"
    echo "skip=$skip"
    echo "reason=$reason"
  } >>"$OUT"
  echo "tested-tree: mode=$MODE result=$result reason: $reason"
  echo "tested-tree \`$MODE\`: **$result**, $reason" >>"$SUMMARY"
  exit 0
}

# Safe default for each mode when something is off.
fallback() {
  case "$MODE" in
    check) finish full "$1" ;;
    *) finish noop "$1" ;;
  esac
}

case "$MODE" in
  record | check) ;;
  *)
    echo "::error::tested-tree: mode must be 'record' or 'check', got '$MODE'"
    exit 1
    ;;
esac

[[ -n "$CACHE" ]] || fallback "HF_CI_CACHE is not set on this runner"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$REPO" != *..* ]] || fallback "unusable GITHUB_REPOSITORY '$REPO'"
command -v jq >/dev/null 2>&1 || fallback "jq is not installed"

DIR="$CACHE/shared/tested-trees/${REPO/\//__}"
HEX_RE='^[0-9a-f]{40}([0-9a-f]{24})?$'

# ---- record ---------------------------------------------------------------------
if [[ "$MODE" == record ]]; then
  [[ "$EVENT" == pull_request ]] || finish noop "record runs on pull_request only (event is '$EVENT')"
  # A fork PR runs code we did not write; never vouch for its tree.
  [[ -n "${TT_HEAD_REPO:-}" && "${TT_HEAD_REPO,,}" == "${REPO,,}" ]] ||
    finish noop "PR head repository '${TT_HEAD_REPO:-unknown}' is not $REPO"
  [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || finish noop "no run id or attempt"
  [[ "${GITHUB_SHA:-}" =~ $HEX_RE ]] || finish noop "GITHUB_SHA is not a commit SHA"

  # The marker vouches for the merge ref's tree, so the workspace must hold it.
  head_now="$(git rev-parse HEAD 2>/dev/null)" || finish noop "cannot resolve HEAD (is the merge ref checked out?)"
  [[ "$head_now" == "$GITHUB_SHA" ]] ||
    finish noop "HEAD ${head_now:0:12} is not the merge commit ${GITHUB_SHA:0:12} (check out the default ref)"

  tree="$(git rev-parse "${GITHUB_SHA}^{tree}" 2>/dev/null)" || finish noop "cannot resolve the tree of ${GITHUB_SHA:0:12} (is the merge ref checked out?)"
  [[ "$tree" =~ $HEX_RE ]] || finish noop "unexpected tree id"

  mkdir -p "$DIR" 2>/dev/null || finish noop "cannot create $DIR"
  tmp="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" || finish noop "cannot write under $DIR"
  if jq -n \
    --argjson run_id "$GITHUB_RUN_ID" \
    --argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg repository "$REPO" \
    --arg merge_commit_sha "$GITHUB_SHA" \
    --arg tree_sha "$tree" \
    '{run_id: $run_id, run_attempt: $run_attempt, repository: $repository, merge_commit_sha: $merge_commit_sha, tree_sha: $tree_sha}' \
    >"$tmp" 2>/dev/null &&
    chmod 0644 "$tmp" && mv -f "$tmp" "$DIR/$tree"; then
    finish recorded "tree ${tree:0:12} of merge ${GITHUB_SHA:0:12} recorded for run $GITHUB_RUN_ID attempt $GITHUB_RUN_ATTEMPT"
  fi
  rm -f "$tmp"
  finish noop "could not write the marker"
fi

# ---- check ----------------------------------------------------------------------
# Fail closed: every `full` below is a decision not to trust the marker.
[[ "$EVENT" == push ]] || finish full "check is for push events (event is '$EVENT')"
[[ -n "$TOKEN" ]] || finish full "no token to verify the marker with"
command -v curl >/dev/null 2>&1 || finish full "curl is not installed"

tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" || finish full "cannot resolve HEAD's tree (no checkout?)"
[[ "$tree" =~ $HEX_RE ]] || finish full "unexpected tree id"

marker="$DIR/$tree"
[[ -f "$marker" && -r "$marker" ]] || finish full "no marker for tree ${tree:0:12}"

fields="$(jq -er '[(.run_id|tostring), (.run_attempt|tostring), .repository, .merge_commit_sha, .tree_sha] | join(" ")' "$marker" 2>/dev/null)" ||
  finish full "marker for tree ${tree:0:12} is unparsable"
read -r run_id attempt m_repo m_merge m_tree extra <<<"$fields"
[[ -z "${extra:-}" && "$run_id" =~ ^[0-9]+$ && "$attempt" =~ ^[0-9]+$ && "$m_merge" =~ $HEX_RE ]] ||
  finish full "marker for tree ${tree:0:12} has malformed fields"
[[ "${m_repo,,}" == "${REPO,,}" ]] || finish full "marker names repository '$m_repo', not $REPO"
[[ "$m_tree" == "$tree" ]] || finish full "marker tree does not match its own file name"

api_get() { # api_get <path> : body on stdout, non-zero on any HTTP or transport error
  # The token goes in through a curl config on stdin, never on the command line
  # (argv is visible to every process on a shared host).
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -fsS --max-time 20 --retry 2 --retry-connrefused -K - \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}$1" 2>/dev/null
}

run_json="$(api_get "/repos/$REPO/actions/runs/$run_id/attempts/$attempt")" ||
  finish full "API error reading run $run_id attempt $attempt"
verdict="$(jq -er --arg id "$run_id" --arg att "$attempt" --arg repo "${REPO,,}" '
    if (.id|tostring) != $id then "run id mismatch"
    elif (.run_attempt|tostring) != $att then "run attempt mismatch"
    elif ((.repository.full_name // "")|ascii_downcase) != $repo then "run belongs to another repository"
    elif ((.head_repository.full_name // "")|ascii_downcase) != $repo then "run is from a fork or an unknown head repository"
    elif .event != "pull_request" then "run event is " + (.event // "null") + ", not pull_request"
    elif .status != "completed" then "run is " + (.status // "null") + ", not completed"
    elif .conclusion != "success" then "run conclusion is " + (.conclusion // "null")
    else "ok" end' <<<"$run_json" 2>/dev/null)" || finish full "run $run_id response is unparsable"
[[ "$verdict" == ok ]] || finish full "run $run_id rejected: $verdict"
# For a pull_request run, head_sha is the PR head commit. It binds the run to
# the merge commit below: a merge commit has the base tip and the PR head as parents.
run_head="$(jq -er '.head_sha' <<<"$run_json" 2>/dev/null)" && [[ "$run_head" =~ $HEX_RE ]] ||
  finish full "run $run_id has no usable head_sha"

commit_json="$(api_get "/repos/$REPO/git/commits/$m_merge")" ||
  finish full "API error reading merge commit ${m_merge:0:12}"
api_tree="$(jq -er '.tree.sha' <<<"$commit_json" 2>/dev/null)" || finish full "merge commit ${m_merge:0:12} response is unparsable"
[[ "$api_tree" == "$tree" ]] || finish full "merge commit ${m_merge:0:12} has tree ${api_tree:0:12}, not ${tree:0:12}"
jq -e --arg h "$run_head" '[.parents[].sha] | index($h) != null' <<<"$commit_json" >/dev/null 2>&1 ||
  finish full "run $run_id (PR head ${run_head:0:12}) did not produce merge commit ${m_merge:0:12}: its head is not a parent"

finish skip-tests "tree ${tree:0:12} was tested green in PR run $run_id attempt $attempt (merge ${m_merge:0:12}, PR head ${run_head:0:12})"
