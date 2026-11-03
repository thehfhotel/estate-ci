#!/usr/bin/env bash
# tested-tree.sh: record / check a "this exact tree was tested" marker.
# See README.md in this directory for the contract and the threat model.
#
# Two proofs, one verification: `record` writes a local marker (fast, same box)
# and posts a commit status on the PR head (works across runner boxes). `check`
# trusts whichever it finds, but only after the GitHub API confirms the run.
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
SHA1_RE='^[0-9a-f]{40}$'
STATUS_CONTEXT="estate-ci/tested-tree"

api_get() { # api_get <path> : body on stdout, non-zero on any HTTP or transport error
  # The token goes in through a curl config on stdin, never on the command line
  # (argv is visible to every process on a shared host).
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -fsS --max-time 20 --retry 2 --retry-connrefused -K - \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}$1" 2>/dev/null
}

# post_status <head_sha> <tree> : best effort. Sets STATUS_NOTE, always returns 0.
# Without `statuses: write` the POST is refused; that only costs the cross-box
# proof, so it is a warning and never a failure.
post_status() {
  local head="$1" tree="$2" desc body url out code msg
  STATUS_NOTE="no commit status posted"
  [[ -n "$TOKEN" ]] || { STATUS_NOTE="no commit status (no token)"; return 0; }
  command -v curl >/dev/null 2>&1 || { STATUS_NOTE="no commit status (curl missing)"; return 0; }
  [[ "$head" =~ $SHA1_RE ]] || { STATUS_NOTE="no commit status (PR head sha unavailable)"; return 0; }
  desc="run=$GITHUB_RUN_ID attempt=$GITHUB_RUN_ATTEMPT merge=$GITHUB_SHA tree=$tree"
  # GitHub rejects descriptions over 140 characters; a SHA-256 repository would exceed it.
  if ((${#desc} > 140)); then
    echo "::warning::tested-tree: commit status description is ${#desc} characters (limit 140); not posted"
    STATUS_NOTE="no commit status (description too long)"
    return 0
  fi
  url="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/$GITHUB_RUN_ID"
  body="$(jq -nc --arg c "$STATUS_CONTEXT" --arg d "$desc" --arg u "$url" \
    '{state: "success", context: $c, description: $d, target_url: $u}')" ||
    { STATUS_NOTE="no commit status (could not build the body)"; return 0; }
  # Body holds no secret, so it may sit on the command line; the token does not.
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" |
    curl -sS --max-time 20 -K - -X POST -w '\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      --data-binary "$body" \
      "${API}/repos/$REPO/statuses/$head" 2>/dev/null)" || out=""
  code="${out##*$'\n'}"
  if [[ "$code" == 201 ]]; then
    STATUS_NOTE="commit status posted on PR head ${head:0:12}"
    return 0
  fi
  msg="$(jq -r '.message // empty' <<<"${out%$'\n'*}" 2>/dev/null | head -c 120)"
  echo "::warning::tested-tree: could not post the commit status (HTTP ${code:-none}${msg:+, $msg}); the caller needs statuses: write. Only the local marker is recorded."
  STATUS_NOTE="commit status not posted (HTTP ${code:-none}); local marker only"
  return 0
}

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

  # Cross-box proof first: it does not depend on this box's cache being writable.
  post_status "${TT_HEAD_SHA:-}" "$tree"

  mkdir -p "$DIR" 2>/dev/null || finish noop "cannot create $DIR ($STATUS_NOTE)"
  tmp="$(mktemp "$DIR/.tmp.XXXXXX" 2>/dev/null)" || finish noop "cannot write under $DIR ($STATUS_NOTE)"
  if jq -n \
    --argjson run_id "$GITHUB_RUN_ID" \
    --argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg repository "$REPO" \
    --arg merge_commit_sha "$GITHUB_SHA" \
    --arg tree_sha "$tree" \
    '{run_id: $run_id, run_attempt: $run_attempt, repository: $repository, merge_commit_sha: $merge_commit_sha, tree_sha: $tree_sha}' \
    >"$tmp" 2>/dev/null &&
    chmod 0644 "$tmp" && mv -f "$tmp" "$DIR/$tree"; then
    finish recorded "tree ${tree:0:12} of merge ${GITHUB_SHA:0:12} recorded for run $GITHUB_RUN_ID attempt $GITHUB_RUN_ATTEMPT; $STATUS_NOTE"
  fi
  rm -f "$tmp"
  finish noop "could not write the marker ($STATUS_NOTE)"
fi

# ---- check ----------------------------------------------------------------------
# Fail closed: every `full` below is a decision not to trust the proof.
[[ "$EVENT" == push ]] || finish full "check is for push events (event is '$EVENT')"
[[ -n "$TOKEN" ]] || finish full "no token to verify the marker with"
command -v curl >/dev/null 2>&1 || finish full "curl is not installed"

tree="$(git rev-parse 'HEAD^{tree}' 2>/dev/null)" || finish full "cannot resolve HEAD's tree (no checkout?)"
[[ "$tree" =~ $HEX_RE ]] || finish full "unexpected tree id"

# verify_run <run_id> <attempt> <merge_sha> [pr_head_sha] : the one verification,
# shared by the marker and the commit-status paths. Returns 1 with WHY set; on
# success sets RUN_HEAD. A claim (marker or status) is never enough by itself:
# the API must confirm the run, and the merge commit it produced.
verify_run() {
  local run_id="$1" attempt="$2" m_merge="$3" want_head="${4:-}"
  local run_json verdict commit_json api_tree
  run_json="$(api_get "/repos/$REPO/actions/runs/$run_id/attempts/$attempt")" ||
    { WHY="API error reading run $run_id attempt $attempt"; return 1; }
  verdict="$(jq -er --arg id "$run_id" --arg att "$attempt" --arg repo "${REPO,,}" '
      if (.id|tostring) != $id then "run id mismatch"
      elif (.run_attempt|tostring) != $att then "run attempt mismatch"
      elif ((.repository.full_name // "")|ascii_downcase) != $repo then "run belongs to another repository"
      elif ((.head_repository.full_name // "")|ascii_downcase) != $repo then "run is from a fork or an unknown head repository"
      elif .event != "pull_request" then "run event is " + (.event // "null") + ", not pull_request"
      elif .status != "completed" then "run is " + (.status // "null") + ", not completed"
      elif .conclusion != "success" then "run conclusion is " + (.conclusion // "null")
      else "ok" end' <<<"$run_json" 2>/dev/null)" || { WHY="run $run_id response is unparsable"; return 1; }
  [[ "$verdict" == ok ]] || { WHY="run $run_id rejected: $verdict"; return 1; }
  # For a pull_request run, head_sha is the PR head commit. It binds the run to
  # the merge commit below: a merge commit has the base tip and the PR head as parents.
  RUN_HEAD="$(jq -er '.head_sha' <<<"$run_json" 2>/dev/null)" && [[ "$RUN_HEAD" =~ $HEX_RE ]] ||
    { WHY="run $run_id has no usable head_sha"; return 1; }
  # The status sits on the PR head; the run must have tested that very commit.
  if [[ -n "$want_head" && "$RUN_HEAD" != "$want_head" ]]; then
    WHY="run $run_id tested ${RUN_HEAD:0:12}, not the PR head ${want_head:0:12}"
    return 1
  fi

  commit_json="$(api_get "/repos/$REPO/git/commits/$m_merge")" ||
    { WHY="API error reading merge commit ${m_merge:0:12}"; return 1; }
  api_tree="$(jq -er '.tree.sha' <<<"$commit_json" 2>/dev/null)" ||
    { WHY="merge commit ${m_merge:0:12} response is unparsable"; return 1; }
  [[ "$api_tree" == "$tree" ]] ||
    { WHY="merge commit ${m_merge:0:12} has tree ${api_tree:0:12}, not ${tree:0:12}"; return 1; }
  jq -e --arg h "$RUN_HEAD" '[.parents[].sha] | index($h) != null' <<<"$commit_json" >/dev/null 2>&1 ||
    { WHY="run $run_id (PR head ${RUN_HEAD:0:12}) did not produce merge commit ${m_merge:0:12}: its head is not a parent"; return 1; }
  return 0
}

# verify_via_status : the cross-box path, used when this box has no marker.
# HEAD -> merged PR(s) -> `estate-ci/tested-tree` statuses on the PR head ->
# verify_run. Returns 1 with WHY set; on success sets PROOF.
verify_via_status() {
  local sha="${GITHUB_SHA:-}" head_now pulls prs pr_n pr_head page st cands c n=0
  local run_id attempt m_merge last=""
  [[ "$sha" =~ $HEX_RE ]] || { WHY="GITHUB_SHA is not a commit SHA"; return 1; }
  head_now="$(git rev-parse HEAD 2>/dev/null)" || { WHY="cannot resolve HEAD"; return 1; }
  [[ "$head_now" == "$sha" ]] ||
    { WHY="HEAD ${head_now:0:12} is not the pushed commit ${sha:0:12} (check out the default ref)"; return 1; }

  pulls="$(api_get "/repos/$REPO/commits/$sha/pulls?per_page=30")" ||
    { WHY="API error listing pull requests of ${sha:0:12} (needs pull-requests: read)"; return 1; }
  # Merged, same-repository PRs only (no forks); three at most.
  prs="$(jq -er --arg repo "${REPO,,}" '
      [.[] | select(.merged_at != null
          and ((.base.repo.full_name // "")|ascii_downcase) == $repo
          and ((.head.repo.full_name // "")|ascii_downcase) == $repo
          and ((.head.sha // "")|test("^[0-9a-f]{40}$")))]
      | .[0:3][] | "\(.number) \(.head.sha)"' <<<"$pulls" 2>/dev/null)" ||
    { WHY="no merged same-repository pull request found for ${sha:0:12}"; return 1; }

  while read -r pr_n pr_head; do
    [[ "$pr_n" =~ ^[0-9]+$ && "$pr_head" =~ $SHA1_RE ]] || continue
    cands=""
    for page in 1 2 3; do
      st="$(api_get "/repos/$REPO/commits/$pr_head/statuses?per_page=100&page=$page")" ||
        { last="API error reading statuses of PR #$pr_n head ${pr_head:0:12} (needs statuses: read)"; break; }
      # Newest first; every field strict; the tree must be HEAD's.
      c="$(jq -r --arg ctx "$STATUS_CONTEXT" --arg tree "$tree" '
          [.[] | select(.context == $ctx and .state == "success")
            | {id: .id, c: (try ((.description // "") | capture("\\Arun=(?<run>[0-9]{1,20}) attempt=(?<att>[0-9]{1,6}) merge=(?<merge>[0-9a-f]{40}) tree=(?<tree>[0-9a-f]{40})\\z")) catch null)}
            | select(.c != null and .c.tree == $tree)]
          | sort_by(.id) | reverse | .[] | "\(.c.run) \(.c.att) \(.c.merge)"' <<<"$st" 2>/dev/null)" ||
        { last="statuses of PR #$pr_n head ${pr_head:0:12} are unparsable"; break; }
      [[ -n "$c" ]] && cands+="$c"$'\n'
      [[ "$(jq 'length' <<<"$st" 2>/dev/null)" == 100 ]] || break
    done
    if [[ -z "$cands" ]]; then
      [[ -n "$last" ]] || last="no $STATUS_CONTEXT status for tree ${tree:0:12} on PR #$pr_n head ${pr_head:0:12}"
      continue
    fi
    n=0
    while read -r run_id attempt m_merge; do
      [[ -n "$run_id" ]] || continue
      ((++n > 3)) && break
      if verify_run "$run_id" "$attempt" "$m_merge" "$pr_head"; then
        PROOF="tree ${tree:0:12} was tested green in PR #$pr_n run $run_id attempt $attempt (merge ${m_merge:0:12}, PR head ${pr_head:0:12}, from its commit status)"
        return 0
      fi
      last="PR #$pr_n: $WHY"
    done <<<"$cands"
  done <<<"$prs"
  WHY="${last:-no usable commit status}"
  return 1
}

marker="$DIR/$tree"
if [[ ! -f "$marker" || ! -r "$marker" ]]; then
  # Marker lives on another runner box (or was never written): ask the API.
  verify_via_status || finish full "no marker for tree ${tree:0:12}, and no commit-status proof: $WHY"
  finish skip-tests "$PROOF"
fi

fields="$(jq -er '[(.run_id|tostring), (.run_attempt|tostring), .repository, .merge_commit_sha, .tree_sha] | join(" ")' "$marker" 2>/dev/null)" ||
  finish full "marker for tree ${tree:0:12} is unparsable"
read -r run_id attempt m_repo m_merge m_tree extra <<<"$fields"
[[ -z "${extra:-}" && "$run_id" =~ ^[0-9]+$ && "$attempt" =~ ^[0-9]+$ && "$m_merge" =~ $HEX_RE ]] ||
  finish full "marker for tree ${tree:0:12} has malformed fields"
[[ "${m_repo,,}" == "${REPO,,}" ]] || finish full "marker names repository '$m_repo', not $REPO"
[[ "$m_tree" == "$tree" ]] || finish full "marker tree does not match its own file name"

verify_run "$run_id" "$attempt" "$m_merge" || finish full "$WHY"

finish skip-tests "tree ${tree:0:12} was tested green in PR run $run_id attempt $attempt (merge ${m_merge:0:12}, PR head ${RUN_HEAD:0:12})"
