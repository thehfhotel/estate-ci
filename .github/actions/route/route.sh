#!/usr/bin/env bash
# route.sh: path-based suite selection for the `route` composite action.
# See README.md in this directory for the contract.
#
# Deliberately NOT `set -e`: every failure path must fail OPEN (run
# everything), and `set -e` would turn a failed git call into a failed job.
set -uo pipefail

SUITES="${ROUTE_SUITES:-}"
DOCS_GLOBS="${ROUTE_DOCS_GLOBS:-}"
SHARED_GLOBS="${ROUTE_SHARED_GLOBS:-}"
UNMATCHED="${ROUTE_UNMATCHED:-all}"
BASE_SHA="${ROUTE_BASE_SHA:-}"
TOKEN="${ROUTE_TOKEN:-}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

# ---- glob -> ERE ------------------------------------------------------------
# Patterns are anchored at the repository root.
#   **/   any number of directories (including none)
#   **    anything, slashes included
#   *     anything except a slash
#   ?     one character except a slash
#   dir/  same as dir/**
# No brace expansion and no character classes: list globs separately.
glob_to_regex() {
  local g="$1" out="" i c n
  [[ "$g" == */ ]] && g="${g}**"
  n=${#g}
  for ((i = 0; i < n; i++)); do
    c="${g:i:1}"
    case "$c" in
      '*')
        if [[ "${g:i:3}" == '**/' ]]; then
          out+='(.*/)?'
          i=$((i + 2))
        elif [[ "${g:i:2}" == '**' ]]; then
          out+='.*'
          i=$((i + 1))
        else
          out+='[^/]*'
        fi
        ;;
      '?') out+='[^/]' ;;
      '^') out+='\^' ;;
      '.' | '+' | '(' | ')' | '|' | '$' | '{' | '}' | '[' | ']' | \\) out+="[$c]" ;;
      *) out+="$c" ;;
    esac
  done
  printf '^%s$' "$out"
}

# Newline-separated regexes from a whitespace/newline-separated glob list.
globs_to_regexes() {
  local list="$1" tok res=""
  set -f
  for tok in $list; do
    [[ "$tok" == \#* ]] && continue
    res+="$(glob_to_regex "$tok")"$'\n'
  done
  set +f
  printf '%s' "$res"
}

# matches_any <file> <newline-separated regexes>
matches_any() {
  local f="$1" re
  while IFS= read -r re; do
    [[ -z "$re" ]] && continue
    [[ "$f" =~ $re ]] && return 0
  done <<<"$2"
  return 1
}

# ---- parse the suite mapping ---------------------------------------------------
suite_names=()
suite_res=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$line" || "$line" == \#* ]] && continue
  if [[ "$line" != *:* ]]; then
    echo "::error::route: bad suites line (want 'name: glob [glob...]'): $line"
    exit 1
  fi
  name="${line%%:*}"
  name="${name%"${name##*[![:space:]]}"}"
  if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    echo "::error::route: bad suite name '$name' (letters, digits, - and _ only)"
    exit 1
  fi
  suite_names+=("$name")
  suite_res+=("$(globs_to_regexes "${line#*:}")")
done <<<"$SUITES"

DOCS_RE="$(globs_to_regexes "$DOCS_GLOBS")"
SHARED_RE="$(globs_to_regexes "$SHARED_GLOBS")"

# ---- emit -----------------------------------------------------------------------
# emit <run_all> <docs_only> <changed_count> <reason> [selected suite names...]
emit() {
  local run_all="$1" docs_only="$2" count="$3" reason="$4"
  shift 4
  local sel=" $* " json="" list="" i n
  for ((i = 0; i < ${#suite_names[@]}; i++)); do
    n="${suite_names[$i]}"
    if [[ "$run_all" == true || "$sel" == *" $n "* ]]; then
      json+="\"$n\":true,"
      list+="\"$n\","
    else
      json+="\"$n\":false,"
    fi
  done
  {
    echo "docs_only=$docs_only"
    echo "run_all=$run_all"
    echo "suites={${json%,}}"
    echo "suite_list=[${list%,}]"
    echo "changed_count=$count"
    echo "reason=$reason"
  } >>"$OUT"
  echo "route: run_all=$run_all docs_only=$docs_only changed=$count suites=[${list%,}] reason: $reason"
  exit 0
}

# Fail open: anything we cannot determine means "run everything".
run_everything() { emit true false 0 "$1"; }

# ---- find what changed ------------------------------------------------------------
case "$BASE_SHA" in
  '' | 0000000000000000000000000000000000000000 | 0000000000000000000000000000000000000000000000000000000000000000)
    run_everything "no base commit for event '${GITHUB_EVENT_NAME:-unknown}' (first push, new branch, or not a PR/push)"
    ;;
esac
[[ "$BASE_SHA" =~ ^[0-9a-f]{40,64}$ ]] || run_everything "base '$BASE_SHA' is not a commit SHA"

git rev-parse --git-dir >/dev/null 2>&1 || run_everything "no git checkout in the workspace (add actions/checkout before this action)"
head_sha="$(git rev-parse HEAD 2>/dev/null)" || run_everything "cannot resolve HEAD"

if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  # Fetch only the base commit. Authenticate this one fetch ourselves, so
  # the caller's checkout can keep persist-credentials: false. Do not add a
  # second Authorization header when the checkout already persisted one.
  server="${GITHUB_SERVER_URL:-https://github.com}"
  fetch_env=()
  if [[ -n "$TOKEN" ]] && ! git config --get-all "http.${server}/.extraheader" >/dev/null 2>&1; then
    b64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
    echo "::add-mask::$b64"
    fetch_env=(GIT_CONFIG_COUNT=1 "GIT_CONFIG_KEY_0=http.${server}/.extraheader" "GIT_CONFIG_VALUE_0=AUTHORIZATION: basic $b64")
  fi
  # A blob-less fetch is enough: the diff below compares trees, not content.
  env ${fetch_env[@]+"${fetch_env[@]}"} git fetch --no-tags --depth=1 --filter=blob:none origin "$BASE_SHA" >/dev/null 2>&1 ||
    env ${fetch_env[@]+"${fetch_env[@]}"} git fetch --no-tags --depth=1 origin "$BASE_SHA" >/dev/null 2>&1 ||
    run_everything "could not fetch base ${BASE_SHA:0:12}"
fi

changed="$(git -c core.quotepath=off diff --name-only --no-renames "$BASE_SHA" "$head_sha" 2>/dev/null)" ||
  run_everything "git diff ${BASE_SHA:0:12}..${head_sha:0:12} failed"
[[ -n "$changed" ]] || run_everything "empty diff against ${BASE_SHA:0:12} (re-run or revert)"
count="$(printf '%s\n' "$changed" | grep -c .)"

# ---- decide -----------------------------------------------------------------------
docs_only=true
shared_hit=false
unmatched_hit=false
declare_hits=()
for ((i = 0; i < ${#suite_names[@]}; i++)); do declare_hits[i]=false; done

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if matches_any "$f" "$SHARED_RE"; then
    shared_hit=true
    docs_only=false
    continue
  fi
  if matches_any "$f" "$DOCS_RE"; then
    continue
  fi
  docs_only=false
  claimed=false
  for ((i = 0; i < ${#suite_names[@]}; i++)); do
    if matches_any "$f" "${suite_res[$i]}"; then
      declare_hits[i]=true
      claimed=true
    fi
  done
  [[ "$claimed" == true ]] || unmatched_hit=true
done <<<"$changed"

if [[ "$docs_only" == true ]]; then
  emit false true "$count" "docs only: $count changed file(s), all match the docs globs"
fi
if [[ "$shared_hit" == true ]]; then
  emit true false "$count" "a shared path changed (workflows/actions or caller-defined shared globs)"
fi
if [[ "$unmatched_hit" == true && "$UNMATCHED" != none ]]; then
  emit true false "$count" "a changed file belongs to no suite and is not docs (unmatched=all)"
fi

selected=()
for ((i = 0; i < ${#suite_names[@]}; i++)); do
  [[ "${declare_hits[$i]}" == true ]] && selected+=("${suite_names[$i]}")
done
emit false false "$count" "selected suites: ${selected[*]:-none}" ${selected[@]+"${selected[@]}"}
