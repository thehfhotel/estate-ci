#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED script — runs after every job, inside the
# runner container, as the container's runner user. It does three things:
#
#  1. Wipes GITHUB_WORKSPACE. Persistent runners (see "Persistent, not
#     ephemeral" in runner/README.md) reuse the same work directory across
#     jobs; a job that does a sparse (or otherwise narrowed) checkout leaves
#     that narrowed tree behind for the NEXT job of the same repo on the same
#     runner, which then sees "no package.json / no Dockerfile" and fails for
#     a reason that has nothing to do with its own change. Some job steps run
#     containerized as root and leave root-owned files behind, which this
#     unprivileged hook cannot remove, so when a docker socket is mounted in
#     the wipe runs as root inside a throwaway sibling container
#     (HOOK_WIPE_IMAGE, default alpine:3.20 — pin it and pre-pull it so the
#     hook never blocks on an image pull). Falls back to a plain `rm -rf`.
#
#  2. Sweeps well-known credential locations under $HOME (~/.ssh, docker
#     config, gh, netrc, git-credentials, aws, kube). Persistent runners keep
#     the SAME $HOME across jobs, so a deploy key or a `docker login` token a
#     job wrote there would otherwise sit there for the next job to read.
#
#  3. Size-gated prune of the shared build caches under $HF_CI_CACHE (cargo
#     target dirs, anonymous docker volumes). See "Cache pruning" in
#     runner/README.md for the design, the levels and the dry run. Skipped
#     entirely when HF_CI_CACHE is unset.
#
# Wire it up by mounting this file (or the whole runner/hooks directory) into
# the container and pointing ACTIONS_RUNNER_HOOK_JOB_COMPLETED at its
# in-container path — see runner/README.md. The script can also be `source`d
# (its main flow is guarded), which is how the prune functions are tested.
#
# Must NEVER fail the job: always exit 0, regardless of what happens above.

# ---------------------------------------------------------------------------
# Cache prune (functions only; nothing runs until hf_prune_launch is called)
# ---------------------------------------------------------------------------
# Knobs (all optional env vars):
#   HF_CI_CACHE              cache root; every <root>/<repo>/target* dir is a
#                            cargo target dir. Unset = prune disabled.
#   HF_CI_PRUNE=0            kill switch.
#   HF_CI_PRUNE_L1_GB=40     level 1 when the root's filesystem has < 40 GB free
#   HF_CI_PRUNE_L2_GB=20     level 2 below 20 GB, level 3 below 10 GB
#   HF_CI_PRUNE_L3_GB=10
#   HF_CI_PRUNE_K1/K2/K3     variants to keep per artifact stem (3 / 2 / 1)
#   HF_CI_PRUNE_MIN_AGE_MIN  never delete anything newer than this (60)
#   HF_CI_PRUNE_JUNK         "dir:days ..." entries under a target dir aged out
#   HF_CI_PRUNE_IMAGE        image for the detached root prune container
#                            (default: the image this runner container runs)
#   HF_CI_PRUNE_LEVEL=1..3   force a level on every root (dry-run previews)
#   PRUNE_DRY_RUN=1          print candidates and sizes only, delete nothing

# Echo the prune level (0..3) for the filesystem holding $1, or nothing when
# df cannot say. Measured PER ROOT: a cache root may be a bind mount of a
# different disk than its siblings, and each disk has its own headroom.
hf_prune_level() {
  local root=$1 avail_gb
  if [ -n "${HF_CI_PRUNE_LEVEL:-}" ]; then echo "$HF_CI_PRUNE_LEVEL"; return 0; fi
  avail_gb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }')
  [ -n "$avail_gb" ] || return 1
  if   [ "$avail_gb" -lt "${HF_CI_PRUNE_L3_GB:-10}" ]; then echo 3
  elif [ "$avail_gb" -lt "${HF_CI_PRUNE_L2_GB:-20}" ]; then echo 2
  elif [ "$avail_gb" -lt "${HF_CI_PRUNE_L1_GB:-40}" ]; then echo 1
  else echo 0
  fi
}

# True when the once-a-day level-1 sweep is due (no stamp, or older than 24 h).
hf_prune_daily_due() {
  local stamp="${HF_CI_CACHE:-}/.prune-stamp"
  [ -f "$stamp" ] || return 0
  [ -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ] && return 1
  return 0
}

# Cheap gate run by the hook after every job: true when any cache root needs a
# prune (a filesystem under its level-1 free-space line, or the daily sweep).
hf_prune_gate() {
  local r lvl
  [ -n "${HF_CI_CACHE:-}" ] && [ -d "$HF_CI_CACHE" ] || return 1
  [ "${HF_CI_PRUNE:-1}" = "0" ] && return 1
  [ "${PRUNE_DRY_RUN:-0}" = "1" ] && return 0
  hf_prune_daily_due && return 0
  for r in "$HF_CI_CACHE"/*/target*; do
    [ -d "$r" ] || continue
    lvl=$(hf_prune_level "$r") || continue
    [ "${lvl:-0}" -ge 1 ] && return 0
  done
  return 1
}

# Candidate selector. Lists entries of one directory (files or dirs) whose
# variant is NOT among the newest $keep for its stem. An entry is
# "<stem>-<hash>[.ext]"; stem and hash are split at the LAST dash. Output is
# one TSV line per deletable entry: <512-byte blocks>\t<stem>\t<name>.
# A variant is only a candidate when its newest file is older than the cutoff
# (epoch seconds), so a build in flight is never touched.
#   $1 dir  $2 find type (f|d)  $3 keep  $4 hash shape (hex16|any)  $5 cutoff
hf_prune_select() {
  local dir=$1 kind=$2 keep=$3 mode=$4 cutoff=$5
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type "$kind" -printf '%T@\t%b\t%f\n' 2>/dev/null |
  awk -F'\t' -v keep="$keep" -v mode="$mode" -v cutoff="$cutoff" '
    {
      name = $3; p = 0
      for (i = length(name); i > 0; i--) if (substr(name, i, 1) == "-") { p = i; break }
      if (p < 2) next
      rest = substr(name, p + 1); d = index(rest, ".")
      h = (d > 0) ? substr(rest, 1, d - 1) : rest
      if (mode == "hex16") { if (length(h) != 16 || h !~ /^[0-9a-f]+$/) next }
      else if (h == "" || h !~ /^[0-9a-z]+$/) next
      stem = substr(name, 1, p - 1)
      key = stem SUBSEP h
      n++; fstem[n] = stem; fhash[n] = h; fname[n] = name; fblk[n] = $2
      if (!(key in mt)) { nh[stem]++; hs[stem, nh[stem]] = h; mt[key] = $1 }
      else if ($1 > mt[key]) mt[key] = $1
    }
    END {
      for (s in nh) {
        m = nh[s]
        if (m <= keep) continue
        for (i = 1; i <= m; i++) {
          ki = s SUBSEP hs[s, i]; newer = 0
          for (j = 1; j <= m; j++) {
            kj = s SUBSEP hs[s, j]
            if (mt[kj] > mt[ki] || (mt[kj] == mt[ki] && j < i)) newer++
          }
          if (newer >= keep && mt[ki] < cutoff) del[ki] = 1
        }
      }
      for (i = 1; i <= n; i++)
        if ((fstem[i] SUBSEP fhash[i]) in del) printf "%d\t%s\t%s\n", fblk[i], fstem[i], fname[i]
    }'
}

# Report (and, unless PRUNE_DRY_RUN=1, delete) the candidates on stdin.
# Candidate lines are the TSV produced by hf_prune_select. Echoes one line
# and adds the freed kilobytes to the global hf_prune_freed_kb.
#   $1 dir (candidates are relative to it)  $2 size source (blocks|du)  $3 label
hf_prune_apply() {
  local dir=$1 sizing=$2 label=$3 cand count kb=0 top
  cand=$(mktemp) || return 0
  cat > "$cand"
  count=$(wc -l < "$cand" | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    if [ "$sizing" = blocks ]; then
      kb=$(awk -F'\t' '{ s += $1 } END { print int(s / 2) }' "$cand")
    else
      kb=$(cut -f3 "$cand" | tr '\n' '\0' | (cd "$dir" && xargs -0 -r du -sk -- 2>/dev/null) | awk '{ s += $1 } END { print int(s) }')
    fi
    if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
      echo "  would remove ${count} ${label}: $((kb / 1024)) MB"
      if [ "$sizing" = blocks ]; then
        top=$(awk -F'\t' '{ b[$2] += $1 } END { for (s in b) printf "%d\t%s\n", b[s] / 2048, s }' "$cand" | sort -rn | head -5 | awk -F'\t' '{ printf "%s%s=%dMB", (NR > 1 ? ", " : ""), $2, $1 }')
        [ -n "$top" ] && echo "    top stems: ${top}"
      fi
    else
      cut -f3 "$cand" | tr '\n' '\0' | (cd "$dir" && xargs -0 -r rm -rf -- 2>/dev/null)
      echo "  removed ${count} ${label}: $((kb / 1024)) MB"
      hf_prune_freed_kb=$((${hf_prune_freed_kb:-0} + kb))
    fi
  fi
  rm -f "$cand"
  return 0
}

# Prune one cargo target dir at level $2 (1..3).
hf_prune_root() {
  local r=$1 lvl=$2 cutoff=$3 keep ik prof exe c pats junk jn jd
  case "$lvl" in 1) keep=${HF_CI_PRUNE_K1:-3};; 2) keep=${HF_CI_PRUNE_K2:-2};; *) keep=${HF_CI_PRUNE_K3:-1};; esac
  ik=$((keep - 1)); [ "$ik" -lt 1 ] && ik=1
  for prof in "$r"/*/; do
    prof=${prof%/}
    [ -d "$prof/deps" ] || continue
    echo " profile ${prof#"$r"/} (keep ${keep} per stem)"
    hf_prune_select "$prof/deps"         f "$keep" hex16 "$cutoff" | hf_prune_apply "$prof/deps"         blocks "dependency/own artifact files"
    hf_prune_select "$prof/build"        d "$keep" hex16 "$cutoff" | hf_prune_apply "$prof/build"        du     "build dirs"
    hf_prune_select "$prof/.fingerprint" d "$keep" hex16 "$cutoff" | hf_prune_apply "$prof/.fingerprint" du     "fingerprint dirs"
    if [ "$lvl" -ge 2 ]; then
      # Level 2+: incremental sessions are the cheapest thing to rebuild.
      [ -d "$prof/incremental" ] && find "$prof/incremental" -mindepth 1 -maxdepth 1 -type d -mmin +"${HF_CI_PRUNE_MIN_AGE_MIN:-60}" -printf '0\t%f\t%f\n' 2>/dev/null |
        hf_prune_apply "$prof/incremental" du "incremental dirs (all)"
    else
      hf_prune_select "$prof/incremental" d "$ik" any "$cutoff" | hf_prune_apply "$prof/incremental" du "incremental dirs"
    fi
    if [ "$lvl" -ge 3 ]; then
      # Level 3 (emergency): drop every own-crate artifact set. Own crates are
      # the workspace executables at the top of the profile dir, plus test_*.
      pats=( -name 'test_*' )
      for exe in "$prof"/*; do
        [ -f "$exe" ] && [ -x "$exe" ] || continue
        c=$(basename "$exe" | tr '-' '_')
        pats+=( -o -name "${c}-*" -o -name "lib${c}-*" )
      done
      find "$prof/deps" -maxdepth 1 -type f \( "${pats[@]}" \) -mmin +"${HF_CI_PRUNE_MIN_AGE_MIN:-60}" -printf '%b\t%f\t%f\n' 2>/dev/null |
        hf_prune_apply "$prof/deps" blocks "own-crate artifact files (all)"
    fi
  done
  # Scratch dirs that only ever accumulate.
  for junk in ${HF_CI_PRUNE_JUNK:-cargo-timings:1 tmp:7 sqlx-prepare-check:7}; do
    jn=${junk%%:*}; jd=${junk##*:}
    [ -d "$r/$jn" ] || continue
    find "$r/$jn" -mindepth 1 -maxdepth 1 -mtime +"$jd" -printf '0\t%f\t%f\n' 2>/dev/null |
      hf_prune_apply "$r/$jn" du "${jn} entries older than ${jd}d"
  done
  return 0
}

# Level-1 docker housekeeping: dangling ANONYMOUS volumes (CI Postgres/Redis
# containers removed without `-v`). `docker volume prune` only touches
# anonymous volumes from Docker 23 on; older daemons would also remove NAMED
# unused volumes, so the call is refused there.
hf_prune_volumes() {
  local major n
  command -v docker >/dev/null 2>&1 || return 0
  major=$(docker version --format '{{.Server.Version}}' 2>/dev/null | cut -d. -f1)
  case "$major" in ''|*[!0-9]*) echo " volumes: docker version unknown, skipped"; return 0;; esac
  if [ "$major" -lt 23 ]; then echo " volumes: docker ${major} would also prune named volumes, skipped"; return 0; fi
  if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
    n=$(docker volume ls -q -f dangling=true -f label=com.docker.volume.anonymous 2>/dev/null | wc -l | tr -d ' ')
    echo " volumes: would prune ${n} dangling anonymous volume(s)"
  else
    echo " volumes: $(docker volume prune -f 2>&1 | tail -1)"
  fi
  return 0
}

# The whole prune. Runs as root in the detached container (or inline as a
# fallback). Single instance via a lock file in the cache root.
hf_prune_main() {
  local r lvl cutoff before after any=0 daily=0
  [ -n "${HF_CI_CACHE:-}" ] && [ -d "$HF_CI_CACHE" ] || return 0
  command -v renice >/dev/null 2>&1 && renice -n 19 -p $$ >/dev/null 2>&1
  command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$HF_CI_CACHE/.prune.lock"
    flock -n 8 || { echo "prune: another instance holds the lock, exiting"; return 0; }
  fi
  # A dry run always previews the level-1 sweep, whatever the stamp says.
  { hf_prune_daily_due || [ "${PRUNE_DRY_RUN:-0}" = "1" ]; } && daily=1
  cutoff=$(( $(date +%s) - ${HF_CI_PRUNE_MIN_AGE_MIN:-60} * 60 ))
  hf_prune_freed_kb=0
  echo "=== $(date -u +%FT%TZ) prune start (dry_run=${PRUNE_DRY_RUN:-0}, daily_due=${daily}) ==="
  for r in "$HF_CI_CACHE"/*/target*; do
    [ -d "$r" ] || continue
    lvl=$(hf_prune_level "$r") || { echo "root ${r}: df failed, skipped"; continue; }
    [ "$lvl" = 0 ] && [ "$daily" = 1 ] && lvl=1
    before=$(df -Pk "$r" 2>/dev/null | awk 'NR==2 { printf "%.1f", $4 / 1048576 }')
    if [ "${lvl:-0}" -lt 1 ]; then echo "root ${r}: ${before} GB free, level 0, nothing to do"; continue; fi
    any=1
    echo "root ${r}: ${before} GB free on its filesystem, level ${lvl}"
    # Race guard: a test job holds <repo>/test-backend.lock for its whole
    # compile + test; do not pull artifacts out from under it (level 3 is an
    # emergency and goes ahead). Holding the lock while pruning also keeps a
    # new test job from starting mid-delete.
    (
      lock="$(dirname "$r")/test-backend.lock"
      if [ -e "$lock" ] && command -v flock >/dev/null 2>&1; then
        exec 9<"$lock"
        if ! flock -n 9; then
          if [ "$lvl" -lt 3 ]; then echo " skipped: test-backend.lock is held"; exit 0; fi
          echo " test-backend.lock held, but level 3 is an emergency: pruning anyway"
        fi
      fi
      hf_prune_root "$r" "$lvl" "$cutoff"
    )
    after=$(df -Pk "$r" 2>/dev/null | awk 'NR==2 { printf "%.1f", $4 / 1048576 }')
    echo " free: ${before} GB -> ${after} GB"
  done
  [ "$any" = 1 ] && hf_prune_volumes
  if [ "${PRUNE_DRY_RUN:-0}" != "1" ]; then
    touch "$HF_CI_CACHE/.prune-stamp" 2>/dev/null
    echo "=== prune done, freed ~$((hf_prune_freed_kb / 1024)) MB in cargo caches ==="
    # Keep the log small.
    if [ -f "$HF_CI_CACHE/prune.log" ] && [ "$(wc -c < "$HF_CI_CACHE/prune.log")" -gt 1048576 ]; then
      tail -n 1500 "$HF_CI_CACHE/prune.log" > "$HF_CI_CACHE/prune.log.tmp" 2>/dev/null &&
        mv "$HF_CI_CACHE/prune.log.tmp" "$HF_CI_CACHE/prune.log"
    fi
  else
    echo "=== dry run done, nothing deleted ==="
  fi
  return 0
}

# Hook-side entry: decide cheaply, then run the prune ROOT-side in a detached
# sibling container so it can delete root-owned caches (a job that builds
# inside a `container:` leaves a root-owned target dir that this unprivileged
# hook cannot touch) and never delays the job that just finished. The fixed
# container name makes it single-instance; a hard timeout bounds the lock it
# holds. Falls back to an inline best-effort prune when docker is unavailable.
hf_prune_launch() {
  local image v envargs=() script fns
  hf_prune_gate || return 0
  for v in HF_CI_CACHE HF_CI_PRUNE_L1_GB HF_CI_PRUNE_L2_GB HF_CI_PRUNE_L3_GB \
           HF_CI_PRUNE_K1 HF_CI_PRUNE_K2 HF_CI_PRUNE_K3 HF_CI_PRUNE_MIN_AGE_MIN \
           HF_CI_PRUNE_JUNK HF_CI_PRUNE_LEVEL PRUNE_DRY_RUN; do
    [ -n "${!v+x}" ] && envargs+=( -e "$v=${!v}" )
  done
  image="${HF_CI_PRUNE_IMAGE:-}"
  if [ -z "$image" ] && command -v docker >/dev/null 2>&1; then
    image=$(docker inspect --format '{{.Config.Image}}' "$(hostname)" 2>/dev/null)
  fi
  if [ -n "$image" ] && command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
    fns=$(declare -f hf_prune_level hf_prune_daily_due hf_prune_select hf_prune_apply \
                     hf_prune_root hf_prune_volumes hf_prune_main)
    script="${fns}
hf_prune_main >> \"\$HF_CI_CACHE/prune.log\" 2>&1"
    if docker run -d --rm --name hf-ci-prune --user 0:0 --entrypoint timeout \
         "${envargs[@]}" \
         -v "${HF_CI_CACHE}:${HF_CI_CACHE}" -v /var/run/docker.sock:/var/run/docker.sock \
         "$image" 1800 bash -c "$script" >/dev/null 2>&1
    then
      echo "job-completed hook: cache prune started as root in the background (log: ${HF_CI_CACHE}/prune.log)"
    else
      echo "job-completed hook: cache prune already running (or docker refused); skipped"
    fi
  else
    echo "job-completed hook: no prune image available; pruning inline as $(id -un)"
    hf_prune_main >> "$HF_CI_CACHE/prune.log" 2>&1 || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main flow. Guarded so `source job-completed.sh` only defines the functions.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  set +e   # the runner may invoke hooks with `bash -e`; this hook must never fail the job

  # Safety guard before the rm -rf below: only ever wipe GITHUB_WORKSPACE when
  # it falls under RUNNER_WORK_PREFIX. Set RUNNER_WORK_PREFIX yourself (e.g. to
  # the host-path prefix shared by every RUNNER_WORKDIR on your box) to pin
  # this guard to a real, known work root — useful when several runners or
  # repos share one host. Left unset, it defaults to the directory two levels
  # above GITHUB_WORKSPACE itself: a job's GITHUB_WORKSPACE is normally
  # "<work-dir>/<repo>/<repo>", so two levels up recovers <work-dir>. That
  # default makes the guard trivially satisfied on an ordinary single-purpose
  # runner (GITHUB_WORKSPACE can only ever be under its own parent), while
  # still keeping the rm scoped to a work directory rather than trusting
  # whatever GITHUB_WORKSPACE happens to hold, verbatim, with no check at all.
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    RUNNER_WORK_PREFIX="${RUNNER_WORK_PREFIX:-$(dirname -- "$(dirname -- "$GITHUB_WORKSPACE")")}"
  else
    RUNNER_WORK_PREFIX="${RUNNER_WORK_PREFIX:-}"
  fi

  HOOK_WIPE_IMAGE="${HOOK_WIPE_IMAGE:-alpine:3.20}"

  if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -n "${RUNNER_WORK_PREFIX}" ] && [ "${GITHUB_WORKSPACE#"$RUNNER_WORK_PREFIX"}" != "$GITHUB_WORKSPACE" ]; then
    wipe_outcome=""
    if command -v docker >/dev/null 2>&1; then
      if docker run --rm -v "${GITHUB_WORKSPACE}:/w" "$HOOK_WIPE_IMAGE" \
           sh -c 'rm -rf -- /w/* /w/.[!.]* 2>/dev/null; true' >/dev/null 2>&1
      then
        wipe_outcome="docker-wipe ok"
      else
        # docker is present but the containerized wipe itself failed (e.g.
        # image pull blocked) — still attempt a plain rm as best effort.
        rm -rf -- "${GITHUB_WORKSPACE}"/* "${GITHUB_WORKSPACE}"/.[!.]* 2>/dev/null || true
        wipe_outcome="fallback (docker wipe failed)"
      fi
    else
      rm -rf -- "${GITHUB_WORKSPACE}"/* "${GITHUB_WORKSPACE}"/.[!.]* 2>/dev/null || true
      wipe_outcome="fallback (docker unavailable)"
    fi
    echo "job-completed hook: cleared GITHUB_WORKSPACE ${GITHUB_WORKSPACE} (${wipe_outcome})"
  else
    echo "job-completed hook: GITHUB_WORKSPACE (${GITHUB_WORKSPACE:-unset}) not under RUNNER_WORK_PREFIX (${RUNNER_WORK_PREFIX:-unset}) — skipped"
  fi

  secret_removed_count=0

  if [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; then
    # Whole ~/.ssh contents, not just a private key file — known_hosts is
    # re-created by whichever job next needs one, so nothing under here is
    # worth keeping between jobs.
    if [ -d "${HOME}/.ssh" ] && [ -n "$(ls -A "${HOME}/.ssh" 2>/dev/null)" ]; then
      rm -rf -- "${HOME}/.ssh"/* "${HOME}/.ssh"/.[!.]* 2>/dev/null || true
      secret_removed_count=$((secret_removed_count + 1))
    fi

    for p in \
      "${HOME}/.docker/config.json" \
      "${HOME}/.config/gh" \
      "${HOME}/.netrc" \
      "${HOME}/.git-credentials" \
      "${HOME}/.aws" \
      "${HOME}/.kube"
    do
      if [ -e "$p" ]; then
        rm -rf -- "$p" 2>/dev/null || true
        secret_removed_count=$((secret_removed_count + 1))
      fi
    done
  fi

  echo "job-completed hook: removed ${secret_removed_count} secret path(s) from HOME (${HOME:-unset})"

  hf_prune_launch || true

  exit 0
fi
