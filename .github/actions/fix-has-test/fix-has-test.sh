#!/usr/bin/env bash
# fix-has-test: see action.yml. Inputs come from FHT_* env vars; the PR title and
# body come from the event JSON file. Nothing from the PR is ever eval'd or
# interpolated into code: it only goes through jq and printf '%s'.
set -euo pipefail

MODE="${FHT_MODE:-warn}"
EVENT="${FHT_EVENT_PATH:-${GITHUB_EVENT_PATH:-}}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "${FHT_EVENT_NAME:-}" != "pull_request" ] || [ ! -f "$EVENT" ]; then
  echo "not a pull_request event: nothing to check"
  exit 0
fi

title="$(jq -r '.pull_request.title // ""' "$EVENT")"
body="$(jq -r '.pull_request.body // ""' "$EVENT")"

shopt -s nocasematch
if ! [[ "$title" =~ ^fix(:|\(|!:) ]]; then
  echo "not a fix PR"
  exit 0
fi
shopt -u nocasematch

# An explicit, reasoned opt-out in the body.
reason="$(printf '%s\n' "$body" | tr -d '\r' | grep -m1 -E '^no-test: .+' || true)"
if [ -n "$reason" ]; then
  reason="${reason:0:200}"
  echo "::notice title=fix-has-test::fix PR without a test, accepted: $reason"
  exit 0
fi

# glob -> anchored ERE. ** crosses '/', and "**/" may match nothing; * does not. '?' and [] are literals.
glob_to_re() {
  local g="$1" re="" c i=0 n=${#1}
  while [ "$i" -lt "$n" ]; do
    c="${g:i:1}"
    if [ "$c" = "*" ]; then
      if [ "${g:i:2}" = "**" ]; then
        if [ "${g:i:3}" = "**/" ]; then re+='(.*/)?'; i=$((i + 3)); continue; fi
        re+='.*'; i=$((i + 2)); continue
      fi
      re+='[^/]*'
    elif [[ "$c" =~ [].\\^\$+?\(\)\{\}\|\[] ]]; then
      re+="\\$c"
    else
      re+="$c"
    fi
    i=$((i + 1))
  done
  printf '^%s$' "$re"
}

# matches_any <file> <newline-list>; entries starting with ! are skipped here.
matches_any() {
  local f="$1" g
  while IFS= read -r g; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"   # trim ends only
    [ -z "$g" ] && continue
    [ "${g:0:1}" = "!" ] && continue
    [[ "$f" =~ $(glob_to_re "$g") ]] && return 0
  done <<<"$2"
  return 1
}

excluded() {
  local f="$1" g
  while IFS= read -r g; do
    g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
    [ "${g:0:1}" = "!" ] || continue
    [[ "$f" =~ $(glob_to_re "${g:1}") ]] && return 0
  done <<<"$2"
  return 1
}

base="${FHT_BASE:-}"
head="${FHT_HEAD:-}"
if [ -z "$base" ] || [ -z "$head" ]; then
  echo "::notice title=fix-has-test::no base/head SHA, skipped"
  exit 0
fi
if ! files="$(git diff --name-only "$base...$head")"; then
  echo "::warning title=fix-has-test::cannot diff $base...$head (checkout needs fetch-depth: 0); skipped"
  exit 0
fi

# A .rs diff that adds a test attribute. The diff is captured first: piping it into
# `grep -q` under pipefail lets git die of SIGPIPE on a big diff (exit 141) and
# miss a real #[test]. '+++ b/' header lines are not added code.
rs_adds_test() {
  local d
  d="$(git diff -U0 "$base...$head" -- "$1")" || return 1
  grep -qE '^\+[^+].*(#\[test\]|#\[tokio::test\]|#\[cfg\(test\)\])|^\+(#\[test\]|#\[tokio::test\]|#\[cfg\(test\)\])' <<<"$d"   # here-string, not a pipe: no SIGPIPE
}

code=() ; tests=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if matches_any "$f" "$FHT_TEST_GLOBS"; then
    tests+=("$f")
  elif [[ "$f" == *.rs ]] && rs_adds_test "$f"; then
    tests+=("$f")
    code+=("$f")   # same file also holds code: it counts for both
  elif matches_any "$f" "$FHT_CODE_GLOBS" && ! excluded "$f" "$FHT_CODE_GLOBS"; then
    code+=("$f")
  fi
done <<<"$files"

if [ "${#code[@]}" -eq 0 ]; then
  echo "fix PR changes no app code: ok"
  exit 0
fi
if [ "${#tests[@]}" -gt 0 ]; then
  echo "fix PR changes code and tests (${tests[0]}): ok"
  exit 0
fi

msg="fix PR changes app code (${code[0]}, ${#code[@]} file(s)) but no test. Add a test that fails without the fix, or put a line 'no-test: <reason>' in the PR body. (hf-agents#259, CI-5)"
printf '### fix-has-test\n\n%s\n' "$msg" >>"$SUMMARY"
if [ "$MODE" = "fail" ]; then
  echo "::error title=fix-has-test::$msg"
  exit 1
fi
echo "::warning title=fix-has-test::$msg (warning only until 2026-11-19)"
exit 0
