#!/usr/bin/env bash
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED script — runs after every job, inside the
# runner container, as the container's runner user. It does four things:
#
#  1. Appends a "completed" row for the job to the CI jobs file (see job-row.sh;
#     job-started.sh writes the matching "started" row). Skipped when
#     HF_CI_CACHE is unset.
#
#  2. Wipes GITHUB_WORKSPACE. Persistent runners (see "Persistent, not
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
#  3. Sweeps well-known credential locations under $HOME (~/.ssh, docker
#     config, gh, netrc, git-credentials, aws, kube). Persistent runners keep
#     the SAME $HOME across jobs, so a deploy key or a `docker login` token a
#     job wrote there would otherwise sit there for the next job to read.
#
#  4. Size-gated prune of the shared build caches under $HF_CI_CACHE (cargo
#     target dirs, anonymous docker volumes, optional builder cache, tested-tree
#     markers). See "Cache pruning" in runner/README.md for the design, the
#     levels and the dry run. Skipped entirely when HF_CI_CACHE is unset.
#
# Wire it up by mounting the whole runner/hooks directory into the container
# and pointing ACTIONS_RUNNER_HOOK_JOB_COMPLETED at the script's in-container
# path — see runner/README.md. The script can also be `source`d (its main flow
# is guarded), which is how the prune functions are tested.
#
# NEVER execute this script on a workstation or the host shell (its credential
# sweep deletes ~/.ssh): it refuses with exit 2 unless HF_CI_RUNNER_CONTAINER=1
# and /.dockerenv exist. Test it only inside a throwaway container.
#
# Inside the runner container it must NEVER fail the job: always exit 0,
# regardless of what happens above.

# ---------------------------------------------------------------------------
# Cache prune (functions only; nothing runs until hf_prune_launch is called)
# ---------------------------------------------------------------------------
# Knobs (all optional env vars):
#   HF_CI_CACHE              cache root; every <root>/<repo>/target* dir is a
#                            cargo target dir. Unset = prune disabled.
#   HF_CI_PRUNE=0            kill switch.
#   HF_CI_PRUNE_L1_GB=20     level 1 when the root's filesystem has < 20 GB free
#   HF_CI_PRUNE_L2_GB=12     level 2 below 12 GB, level 3 below 6 GB
#   HF_CI_PRUNE_L3_GB=6
#   HF_CI_PRUNE_K1/K2/K3     variants to keep per OWN-crate artifact stem
#                            (8 / 2 / 1), newest by mtime
#   HF_CI_PRUNE_TP_DAYS_L1/L2/L3
#                            a THIRD-PARTY artifact is deleted only when its
#                            atime is older than this many days (3 / 1 / 0;
#                            0 = older than HF_CI_PRUNE_MIN_AGE_MIN)
#   HF_CI_PRUNE_OWN          extra own-crate stems, space separated (crates are
#                            detected automatically, see hf_prune_own_stems)
#   HF_CI_PRUNE_MIN_AGE_MIN  never delete anything newer than this (60)
#   HF_CI_PRUNE_JUNK         "dir:days ..." entries under a target dir aged out
#   HF_CI_PRUNE_IMAGE        image for the detached root prune container
#                            (default: the image this runner container runs)
#   HF_CI_CGROUP_PARENT      optional --cgroup-parent for the sibling containers
#                            this hook starts (wipe and prune)
#   HF_CI_PRUNE_LEVEL=1..3   force a level on every root (dry-run previews)
#   PRUNE_DRY_RUN=1          print candidates and sizes only, delete nothing
#
# Root-filesystem knobs (the filesystem that holds / may also host production
# services; cache roots bind-mounted from it, and the builder state, count
# against its free space):
#   HF_CI_ROOT_FLOOR_GB=40        when the filesystem holding / has < 40 GB
#                                 free: prune the builder cache (oldest first)
#                                 down to HF_CI_BUILDER_FLOOR_KEEP_GB, then, if
#                                 still under the floor, level-1 prune every
#                                 cargo target dir that lives on that filesystem.
#   HF_CI_ROOT_FLOOR_COOLDOWN_MIN=30  do not repeat the floor action within
#                                 this many minutes (anti-thrash), unless the
#                                 root is under the L1 emergency line.
#   HF_CI_BUILDER_FLOOR_KEEP_GB=20    builder keep-storage for the floor action.
#   HF_CI_CACHE_CAPS              "<repo>:<GB> ..." — when du of
#                                 $HF_CI_CACHE/<repo> exceeds its cap, level-1
#                                 prune that repo's target dirs. du is slow, so
#                                 it runs only in the detached root prune
#                                 container, at most every
#   HF_CI_CAP_CHECK_MIN=60        minutes. Unset = no caps.
#   HF_CI_BUILDER_CONTAINER       name of the persistent BuildKit builder
#                                 container; unset = no builder steps.
#   HF_CI_BUILDER_KEEP_GB=30      belt-and-braces cap on the builder cache,
#                                 applied with the hourly cap check.
#   HF_CI_ROOTFS_PROBE            default /etc/hostname (a file bind-mounted
#                                 from the host, so df on it reports the host
#                                 root filesystem from inside any container).
#
# Tested-tree markers (written once by CI, never touched again):
#   HF_CI_TESTED_TREES_DIR        default $HF_CI_CACHE/shared/tested-trees; must
#                                 resolve under $HF_CI_CACHE or the prune skips it.
#   HF_CI_TESTED_TREES_DAYS=30    markers older than this (mtime) are deleted.

# Shared awk helpers for artifact names. parse(name, mode) splits
# "<stem>-<hash>[.ext]" at the LAST dash and sets P_ok, P_stem, P_hash, P_ext,
# and P_norm: the stem as cargo spells the CRATE (lib prefix of library files
# stripped, dashes to underscores), so deps files (libserde_json-<hash>.rlib),
# .fingerprint dirs and build dirs (serde_json-<hash>) of one crate agree.
# mode hex16 = hash must be 16 hex chars; any = [0-9a-z]+ (incremental dirs).
hf_prune_awklib() {
  cat <<'AWKEOF'
function parse(name, mode,    p, i, rest, d, h, ext) {
  P_ok = 0; p = 0
  for (i = length(name); i > 0; i--) if (substr(name, i, 1) == "-") { p = i; break }
  if (p < 2) return
  rest = substr(name, p + 1); d = index(rest, ".")
  h = (d > 0) ? substr(rest, 1, d - 1) : rest
  ext = (d > 0) ? substr(rest, d + 1) : ""
  if (mode == "hex16") { if (length(h) != 16 || h !~ /^[0-9a-f]+$/) return }
  else if (h == "" || h !~ /^[0-9a-z]+$/) return
  P_stem = substr(name, 1, p - 1); P_hash = h; P_ext = ext
  P_norm = P_stem
  if (ext == "rlib" || ext == "rmeta" || ext == "so" || ext == "dylib" || ext == "a" || ext == "dll") sub(/^lib/, "", P_norm)
  gsub(/-/, "_", P_norm)
  P_ok = 1
}
AWKEOF
}

# Symlink containment. The cache is writable by every job, so a job can plant a
# symlink where the prune expects a directory (<repo>/target-x -> /elsewhere, a
# profile dir, a junk dir). The prune runs as root and must never delete through
# one. Rules: never follow a link (find -P everywhere, never -L), skip any root,
# profile, scratch dir or candidate that IS a link, and have hf_prune_apply (the
# one delete choke point) prove that the directory it deletes in resolves to a
# place under the real path of the root being pruned.
#
# True when the real path of $1 is strictly under the real path of $2.
hf_prune_within() {
  local p b
  # -m: components that do not exist yet (a marker dir about to be created) are fine.
  p=$(readlink -m -- "$1" 2>/dev/null || readlink -f -- "$1" 2>/dev/null) || return 1
  b=$(readlink -m -- "$2" 2>/dev/null || readlink -f -- "$2" 2>/dev/null) || return 1
  [ -n "$p" ] && [ -n "$b" ] || return 1
  case "$p" in "$b"/*) return 0;; esac
  return 1
}

# True when $1 may be pruned as a cargo target root: a real directory (not a
# link), whose repo directory is not a link either, and (when HF_CI_CACHE is
# set) which resolves to somewhere under the cache root.
hf_prune_root_ok() {
  local r=$1
  [ -d "$r" ] && [ ! -L "$r" ] || return 1
  [ ! -L "$(dirname -- "$r")" ] || return 1
  if [ -n "${HF_CI_CACHE:-}" ]; then hf_prune_within "$r" "$HF_CI_CACHE" || return 1; fi
  return 0
}

# True unless a prune was launched less than HF_CI_PRUNE_RELAUNCH_MIN (10)
# minutes ago. Under an emergency (low free space) every job end would otherwise
# start another full sweep.
hf_prune_relaunch_ok() {
  local stamp="${HF_CI_CACHE:-}/.launch-stamp"
  [ "${PRUNE_DRY_RUN:-0}" = "1" ] && return 0
  [ -f "$stamp" ] || return 0
  [ -z "$(find -P "$stamp" -mmin -"${HF_CI_PRUNE_RELAUNCH_MIN:-10}" 2>/dev/null)" ]
}

# Echo the prune level (0..3) for the filesystem holding $1, or nothing when
# df cannot say. Measured PER ROOT: a cache root may be a bind mount of a
# different disk than its siblings, and each disk has its own headroom.
hf_prune_level() {
  local root=$1 avail_gb
  if [ -n "${HF_CI_PRUNE_LEVEL:-}" ]; then echo "$HF_CI_PRUNE_LEVEL"; return 0; fi
  avail_gb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }')
  [ -n "$avail_gb" ] || return 1
  if   [ "$avail_gb" -lt "${HF_CI_PRUNE_L3_GB:-6}" ]; then echo 3
  elif [ "$avail_gb" -lt "${HF_CI_PRUNE_L2_GB:-12}" ]; then echo 2
  elif [ "$avail_gb" -lt "${HF_CI_PRUNE_L1_GB:-20}" ]; then echo 1
  else echo 0
  fi
}

# True when the once-a-day level-1 sweep is due (no stamp, or older than 24 h).
hf_prune_daily_due() {
  local stamp="${HF_CI_CACHE:-}/.prune-stamp"
  [ -f "$stamp" ] || return 0
  [ -n "$(find -P "$stamp" -mmin -1440 2>/dev/null)" ] && return 1
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
  hf_prune_rootfs_due && return 0
  for r in "$HF_CI_CACHE"/*/target*; do
    hf_prune_root_ok "$r" || continue
    lvl=$(hf_prune_level "$r") || continue
    [ "${lvl:-0}" -ge 1 ] && return 0
  done
  return 1
}

# Candidate selector for OWN-crate artifacts (or every stem, scope=all). Lists
# entries of one directory (files or dirs) whose variant is NOT among the
# newest $keep for its stem, newest by mtime. An entry is "<stem>-<hash>[.ext]"
# (see hf_prune_awklib). Output is one TSV line per deletable entry:
# <512-byte blocks>\t<stem>\t<name>. A variant is only a candidate when its
# newest file is older than the cutoff (epoch seconds), so a build in flight is
# never touched.
#   $1 dir  $2 find type (f|d)  $3 keep  $4 hash shape (hex16|any)  $5 cutoff
#   $6 scope: own (only stems listed in file $7) | all (default)
hf_prune_select() {
  local dir=$1 kind=$2 keep=$3 mode=$4 cutoff=$5 scope=${6:-all} ownfile=${7:-}
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  find -P "$dir" -mindepth 1 -maxdepth 1 -type "$kind" -printf '%T@\t%b\t%f\n' 2>/dev/null |
  awk -F'\t' -v keep="$keep" -v mode="$mode" -v cutoff="$cutoff" -v scope="$scope" -v ownfile="$ownfile" \
    "$(hf_prune_awklib)"'
    BEGIN { if (ownfile != "") while ((getline l < ownfile) > 0) own[l] = 1 }
    {
      parse($3, mode); if (!P_ok) next
      if (scope == "own" && !(P_norm in own)) next
      stem = P_stem; h = P_hash
      key = stem SUBSEP h
      n++; fstem[n] = stem; fhash[n] = h; fname[n] = $3; fblk[n] = $2
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

# Candidate selector for THIRD-PARTY artifacts: every hex16 entry whose crate is
# NOT in the own-stem file, and whose variant (crate + hash, across deps, build
# and .fingerprint, see hf_prune_atime_index) was last ACCESSED before $3
# (epoch seconds). Keep-newest-K by mtime is wrong for these: cargo reuses an
# old dependency artifact without touching its mtime, so mtime ranks a hot
# artifact as stale. Same TSV output as hf_prune_select.
#   $1 dir  $2 find type (f|d)  $3 atime cutoff  $4 own-stem file  $5 atime index
hf_prune_select_tp() {
  local dir=$1 kind=$2 tpcutoff=$3 ownfile=$4 hotfile=$5
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  find -P "$dir" -mindepth 1 -maxdepth 1 -type "$kind" -printf '%T@\t%b\t%f\n' 2>/dev/null |
  awk -F'\t' -v tpc="$tpcutoff" -v ownfile="$ownfile" -v hotfile="$hotfile" \
    "$(hf_prune_awklib)"'
    BEGIN {
      if (ownfile != "") while ((getline l < ownfile) > 0) own[l] = 1
      if (hotfile != "") while ((getline l < hotfile) > 0) { split(l, a, "\t"); hot[a[1] SUBSEP a[2]] = a[3] + 0 }
    }
    {
      parse($3, "hex16"); if (!P_ok) next
      if (P_norm in own) next
      key = P_norm SUBSEP P_hash
      at = (key in hot) ? hot[key] : $1 + 0
      if (at < tpc) printf "%d\t%s\t%s\n", $2, P_stem, $3
    }'
}

# The crates this repo OWNS in one cargo profile dir, one normalized stem per
# line. Own = the workspace's own crates, whose dep-info (deps/*.d) lists their
# sources as RELATIVE paths, where registry and git dependencies list absolute
# ones; plus the executables at the top of the profile dir; plus
# HF_CI_PRUNE_OWN. Build-script stems (build_script_*) are shared by every
# package, so they are never own. NOTE: this reads the .d files, which bumps
# their atime, so the atime index never counts .d files.
hf_prune_own_stems() {
  local prof=$1 exe o
  {
    find -P "$prof/deps" -maxdepth 1 -type f -name '*.d' -exec head -qn1 {} + 2>/dev/null |
    awk "$(hf_prune_awklib)"'{
      ci = index($0, ": "); if (ci < 2) next
      tgt = substr($0, 1, ci - 1); src = substr($0, ci + 2)
      n = split(tgt, a, "/"); parse(a[n], "hex16"); if (!P_ok) next
      if (P_norm ~ /^build_script_/) next
      sub(/^ +/, "", src); split(src, s, " ")
      if (s[1] != "" && substr(s[1], 1, 1) != "/") print P_norm
    }'
    for exe in "$prof"/*; do
      [ -f "$exe" ] && [ -x "$exe" ] || continue
      basename "$exe" | tr '-' '_'
    done
    for o in ${HF_CI_PRUNE_OWN:-}; do printf '%s\n' "$o" | tr '-' '_'; done
  } | sort -u
}

# Last-access index of one cargo profile dir: TSV <crate>\t<hash>\t<newest atime
# of any file of that variant>. Variants are keyed by (normalized crate, hash)
# and span deps files (not .d, see hf_prune_own_stems), build/<pkg>-<hash> and
# .fingerprint/<pkg>-<hash> trees, so a unit whose fingerprint was read by a
# fully fresh build counts as in use even when its rlib was not opened.
hf_prune_atime_index() {
  local prof=$1
  {
    find -P "$prof/deps" -maxdepth 1 -type f ! -name '*.d' -printf '%A@\t%f\n' 2>/dev/null
    find -P "$prof/build" "$prof/.fingerprint" -mindepth 2 -type f -printf '%A@\t%P\n' 2>/dev/null
  } | awk -F'\t' "$(hf_prune_awklib)"'{
      name = $2; n = index(name, "/"); if (n) name = substr(name, 1, n - 1)
      parse(name, "hex16"); if (!P_ok) next
      k = P_norm SUBSEP P_hash
      if (!(k in mx) || $1 + 0 > mx[k]) mx[k] = $1 + 0
    }
    END { for (k in mx) { split(k, a, SUBSEP); printf "%s\t%s\t%.0f\n", a[1], a[2], mx[k] } }'
}

# True unless the filesystem holding $1 is mounted noatime. The third-party
# rule needs atime to move on access: relatime (the default; at most one update
# a day) is fine, noatime is not. Unknown counts as fine.
hf_prune_atime_ok() {
  local d
  d=$(readlink -f "$1" 2>/dev/null) || d=$1
  awk -v d="$d" '{
      mp = $5
      if (mp == d || mp == "/" || index(d, mp "/") == 1) if (length(mp) >= best) { best = length(mp); opts = $6 }
    }
    END { exit (opts ~ /(^|,)noatime(,|$)/) ? 1 : 0 }' "${HF_CI_MOUNTINFO:-/proc/self/mountinfo}" 2>/dev/null
  [ $? -ne 1 ]
}

# Report (and, unless PRUNE_DRY_RUN=1, delete) the candidates on stdin.
# Candidate lines are the TSV produced by hf_prune_select. Echoes one line and
# records the freed kilobytes: one number per line appended to the file named by
# $hf_prune_freed_file (set by hf_prune_main). This runs as the right-hand side
# of a pipeline, i.e. in a subshell, so a plain variable would be lost.
# This is the only place that deletes. It refuses unless $dir is a real directory
# (not a link) that resolves to a place under $hf_prune_base (the real path of
# the root being pruned, set by hf_prune_root); drops candidates that are links
# or whose name has a path separator; and deletes by relative name from inside
# the verified directory, so no path component is resolved a second time.
#   $1 dir (candidates are relative to it)  $2 size source (blocks|du)  $3 label
hf_prune_apply() {
  local dir=$1 sizing=$2 label=$3 cand safe count kb=0 top here b st n
  cand=$(mktemp) || return 0
  cat > "$cand"
  if [ -s "$cand" ]; then
    here=""
    if [ ! -L "$dir" ] && [ -n "${hf_prune_base:-}" ]; then here=$(cd -P -- "$dir" 2>/dev/null && pwd -P); fi
    if [ -z "$here" ] || ! hf_prune_within "$here" "$hf_prune_base"; then
      echo "  refused ${label}: ${dir} is a symlink or resolves outside the prune root, skipped"
      rm -f "$cand"; return 0
    fi
    safe=$(mktemp) || { rm -f "$cand"; return 0; }
    while IFS=$'\t' read -r b st n; do
      case "$n" in ''|.|..|*/*) continue;; esac
      [ -L "$here/$n" ] && continue
      printf '%s\t%s\t%s\n' "$b" "$st" "$n"
    done < "$cand" > "$safe"
    mv -f "$safe" "$cand"
  fi
  count=$(wc -l < "$cand" | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    if [ "$sizing" = blocks ]; then
      kb=$(awk -F'\t' '{ s += $1 } END { print int(s / 2) }' "$cand")
    else
      # Same landing check as the delete below: size only the verified directory.
      kb=$(cut -f3 "$cand" | tr '\n' '\0' |
        ( cd -P -- "$here" 2>/dev/null && [ "$(pwd -P)" = "$here" ] && hf_prune_within "$here" "$hf_prune_base" && xargs -0 -r du -sk -- 2>/dev/null ) |
        awk '{ s += $1 } END { print int(s) }')
    fi
    if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
      echo "  would remove ${count} ${label}: $((kb / 1024)) MB"
      if [ "$sizing" = blocks ]; then
        top=$(awk -F'\t' '{ b[$2] += $1 } END { for (s in b) printf "%d\t%s\n", b[s] / 2048, s }' "$cand" | sort -rn | head -5 | awk -F'\t' '{ printf "%s%s=%dMB", (NR > 1 ? ", " : ""), $2, $1 }')
        [ -n "$top" ] && echo "    top stems: ${top}"
      fi
    else
      # Re-verify the directory we actually landed in (a parent may have been
      # swapped for a link since the check above) before removing anything: it
      # must be exactly the directory verified above AND still under the root.
      cut -f3 "$cand" | tr '\n' '\0' |
        ( cd -P -- "$here" 2>/dev/null && [ "$(pwd -P)" = "$here" ] && hf_prune_within "$here" "$hf_prune_base" && xargs -0 -r rm -rf -- 2>/dev/null )
      echo "  removed ${count} ${label}: $((kb / 1024)) MB"
      [ -n "${hf_prune_freed_file:-}" ] && echo "$kb" >> "$hf_prune_freed_file"
    fi
  fi
  rm -f "$cand"
  return 0
}

# Prune one cargo target dir at level $2 (1..3). Per profile dir:
#   own crates     keep the newest K per stem by mtime (K by level)
#   third-party    delete a variant only when its atime is older than the
#                  level's TP days (see the knobs above)
# Without usable atime (noatime mount) or without any detected own crate, the
# profile falls back to keep-K by mtime for every stem, as before.
hf_prune_root() {
  local r=$1 lvl=$2 cutoff=$3 keep ik tpd tpcut prof exe c pats junk jn jd own hot scope olabel note nown
  hf_prune_root_ok "$r" || { echo " refused: ${r} is a symlink or outside the cache root, skipped"; return 0; }
  hf_prune_base=$(readlink -f -- "$r" 2>/dev/null) || return 0
  case "$lvl" in
    1) keep=${HF_CI_PRUNE_K1:-8}; tpd=${HF_CI_PRUNE_TP_DAYS_L1:-3};;
    2) keep=${HF_CI_PRUNE_K2:-2}; tpd=${HF_CI_PRUNE_TP_DAYS_L2:-1};;
    *) keep=${HF_CI_PRUNE_K3:-1}; tpd=${HF_CI_PRUNE_TP_DAYS_L3:-0};;
  esac
  ik=$((keep - 1)); [ "$ik" -lt 1 ] && ik=1
  tpcut=$(( $(date +%s) - tpd * 86400 )); [ "$tpcut" -gt "$cutoff" ] && tpcut=$cutoff
  for prof in "$r"/*/; do
    prof=${prof%/}
    [ -L "$prof" ] && { echo " profile ${prof#"$r"/}: symlink, skipped"; continue; }
    [ -d "$prof/deps" ] && [ ! -L "$prof/deps" ] || continue
    own=$(mktemp) || continue; hot=$(mktemp) || { rm -f "$own"; continue; }
    scope=all; olabel="all-stem"; note="keep ${keep} per stem, all stems"
    if hf_prune_atime_ok "$prof"; then
      hf_prune_own_stems "$prof" > "$own"
      nown=$(wc -l < "$own" | tr -d ' ')
      if [ "${nown:-0}" -gt 0 ]; then
        scope=own; olabel="own"
        hf_prune_atime_index "$prof" > "$hot"
        note="own crates (${nown} stems): keep ${keep} per stem; third-party: atime older than ${tpd} d"
      else
        note="no own crates detected: keep ${keep} per stem, all stems"
      fi
    else
      note="filesystem mounted noatime, atime rule off: keep ${keep} per stem, all stems"
    fi
    echo " profile ${prof#"$r"/} (${note})"
    hf_prune_select "$prof/deps"         f "$keep" hex16 "$cutoff" "$scope" "$own" | hf_prune_apply "$prof/deps"         blocks "${olabel} artifact files"
    hf_prune_select "$prof/build"        d "$keep" hex16 "$cutoff" "$scope" "$own" | hf_prune_apply "$prof/build"        du     "${olabel} build dirs"
    hf_prune_select "$prof/.fingerprint" d "$keep" hex16 "$cutoff" "$scope" "$own" | hf_prune_apply "$prof/.fingerprint" du     "${olabel} fingerprint dirs"
    if [ "$scope" = own ]; then
      hf_prune_select_tp "$prof/deps"         f "$tpcut" "$own" "$hot" | hf_prune_apply "$prof/deps"         blocks "third-party artifact files (atime > ${tpd} d)"
      hf_prune_select_tp "$prof/build"        d "$tpcut" "$own" "$hot" | hf_prune_apply "$prof/build"        du     "third-party build dirs (atime > ${tpd} d)"
      hf_prune_select_tp "$prof/.fingerprint" d "$tpcut" "$own" "$hot" | hf_prune_apply "$prof/.fingerprint" du     "third-party fingerprint dirs (atime > ${tpd} d)"
    fi
    rm -f "$own" "$hot"
    if [ "$lvl" -ge 2 ]; then
      # Level 2+: incremental sessions are the cheapest thing to rebuild.
      [ -d "$prof/incremental" ] && [ ! -L "$prof/incremental" ] && find -P "$prof/incremental" -mindepth 1 -maxdepth 1 -type d -mmin +"${HF_CI_PRUNE_MIN_AGE_MIN:-60}" -printf '0\t%f\t%f\n' 2>/dev/null |
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
      find -P "$prof/deps" -maxdepth 1 -type f \( "${pats[@]}" \) -mmin +"${HF_CI_PRUNE_MIN_AGE_MIN:-60}" -printf '%b\t%f\t%f\n' 2>/dev/null |
        hf_prune_apply "$prof/deps" blocks "own-crate artifact files (all)"
    fi
  done
  # Scratch dirs that only ever accumulate.
  for junk in ${HF_CI_PRUNE_JUNK:-cargo-timings:1 tmp:7 sqlx-prepare-check:7}; do
    jn=${junk%%:*}; jd=${junk##*:}
    case "$jn" in ''|.|..|*/*) continue;; esac
    [ -d "$r/$jn" ] && [ ! -L "$r/$jn" ] || continue
    find -P "$r/$jn" -mindepth 1 -maxdepth 1 -mtime +"$jd" -printf '0\t%f\t%f\n' 2>/dev/null |
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

# Free KB on the filesystem holding / (also Docker's data root on a typical
# host). df on /etc/hostname resolves to that filesystem from inside a
# container too.
hf_prune_rootfs_free_kb() {
  df -Pk "${HF_CI_ROOTFS_PROBE:-/etc/hostname}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ { print $4; ok=1 } END { exit ok ? 0 : 1 }'
}

# True when directory $1 is on the same filesystem as /.
hf_prune_on_rootfs() {
  local a b
  a=$(df -P "$1" 2>/dev/null | awk 'NR==2 { print $1 }')
  b=$(df -P "${HF_CI_ROOTFS_PROBE:-/etc/hostname}" 2>/dev/null | awk 'NR==2 { print $1 }')
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# Cheap check (no du) run by the hook after every job: true when the root
# floor action is due (root under the floor and the cooldown has elapsed, or
# under the L1 emergency line) or the hourly cap check is due.
hf_prune_rootfs_due() {
  local free_kb floor_kb stamp
  free_kb=$(hf_prune_rootfs_free_kb) || return 1
  floor_kb=$(( ${HF_CI_ROOT_FLOOR_GB:-40} * 1048576 ))
  if [ "$free_kb" -lt "$floor_kb" ]; then
    [ "$free_kb" -lt $(( ${HF_CI_PRUNE_L1_GB:-20} * 1048576 )) ] && return 0
    stamp="${HF_CI_CACHE:-}/.floor-stamp"
    [ -f "$stamp" ] || return 0
    [ -z "$(find -P "$stamp" -mmin -"${HF_CI_ROOT_FLOOR_COOLDOWN_MIN:-30}" 2>/dev/null)" ] && return 0
  fi
  if [ -n "${HF_CI_CACHE_CAPS:-}" ] || [ -n "${HF_CI_BUILDER_CONTAINER:-}" ]; then
    stamp="${HF_CI_CACHE:-}/.cap-stamp"
    [ -f "$stamp" ] || return 0
    [ -z "$(find -P "$stamp" -mmin -"${HF_CI_CAP_CHECK_MIN:-60}" 2>/dev/null)" ] && return 0
  fi
  return 1
}

# The lock-guarded per-root prune (extracted from hf_prune_main so the root-fs
# steps reuse it). A test job holds <repo>/test-backend.lock for its whole
# compile + test; do not pull artifacts out from under it (level 3 is an
# emergency and goes ahead). Holding the lock while pruning also keeps a new
# test job from starting mid-delete.   $1 root  $2 level  $3 cutoff
hf_prune_root_locked() {
  local r=$1 lvl=$2 cutoff=$3
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
}

# Prune the persistent BuildKit builder cache (HF_CI_BUILDER_CONTAINER) to $1 GB
# (least recently used first; records in use by a running build are never
# touched). Goes through `buildctl` INSIDE the builder container, not
# `docker buildx`: buildx would rewrite files in the runners' BUILDX_CONFIG
# (owned by the runner user, mode 0600) as root. No-op when no builder
# container is configured.   $1 keep GB  $2 reason
hf_prune_builder() {
  local keep=$1 why=$2 c="${HF_CI_BUILDER_CONTAINER:-}" tot
  [ -n "$c" ] || return 0
  command -v docker >/dev/null 2>&1 || { echo " builder: no docker CLI, skipped"; return 0; }
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ]; then
    echo " builder: container ${c} not running, skipped"; return 0
  fi
  tot=$(docker exec "$c" buildctl du 2>/dev/null | awk '/^Total:/ { print $2 }')
  if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
    echo " builder (${why}): would run buildctl prune --all --keep-storage ${keep} GB (cache total now ${tot:-unknown})"
  else
    echo " builder (${why}): cache total ${tot:-unknown}; pruning to ${keep} GB"
    docker exec "$c" buildctl prune --all --keep-storage "$((keep * 1000))" 2>&1 | tail -1 | sed 's/^/  /'
    echo " builder: cache total now $(docker exec "$c" buildctl du 2>/dev/null | awk '/^Total:/ { print $2 }')"
  fi
  return 0
}

# Root-filesystem steps (see the knobs doc at the top). Runs first in
# hf_prune_main.
#   1. root filesystem under the floor -> builder cache, then level 1 on every
#      cargo target dir that lives on that filesystem.
#   2. each HF_CI_CACHE_CAPS entry over its du cap (hourly) -> level 1 on that
#      repo's target dirs; then the builder keep-cap.
# $1 = prune cutoff (epoch).
hf_prune_rootfs() {
  local cutoff=$1 free_kb floor_gb dry=${PRUNE_DRY_RUN:-0} stamp r entry repo cap dir du_kb
  floor_gb=${HF_CI_ROOT_FLOOR_GB:-40}
  free_kb=$(hf_prune_rootfs_free_kb) || { echo "rootfs: df on root failed, skipped"; return 0; }
  echo "rootfs: root fs $((free_kb / 1048576)) GB free (floor ${floor_gb} GB)"
  if [ "$free_kb" -lt $((floor_gb * 1048576)) ]; then
    stamp="$HF_CI_CACHE/.floor-stamp"
    if [ "$dry" != 1 ] && [ "$free_kb" -ge $(( ${HF_CI_PRUNE_L1_GB:-20} * 1048576 )) ] \
       && [ -f "$stamp" ] && [ -n "$(find -P "$stamp" -mmin -"${HF_CI_ROOT_FLOOR_COOLDOWN_MIN:-30}" 2>/dev/null)" ]; then
      echo " floor: acted less than ${HF_CI_ROOT_FLOOR_COOLDOWN_MIN:-30} min ago, cooling down"
    else
      echo " floor: root fs under ${floor_gb} GB free, pruning CI-owned data on it (oldest first)"
      hf_prune_builder "${HF_CI_BUILDER_FLOOR_KEEP_GB:-20}" "floor"
      free_kb=$(hf_prune_rootfs_free_kb) || free_kb=0
      if [ "$dry" = 1 ] || [ "$free_kb" -lt $((floor_gb * 1048576)) ]; then
        echo " floor: $((free_kb / 1048576)) GB free after builder prune, level-1 prune of cache roots on the root fs"
        for r in "$HF_CI_CACHE"/*/target*; do
          hf_prune_root_ok "$r" && hf_prune_on_rootfs "$r" || continue
          echo "root ${r}: floor-driven level 1"
          hf_prune_root_locked "$r" 1 "$cutoff"
        done
      fi
      [ "$dry" = 1 ] || touch "$stamp" 2>/dev/null
      echo " floor: root fs now $(( $(hf_prune_rootfs_free_kb || echo 0) / 1048576 )) GB free"
    fi
  fi
  if [ -n "${HF_CI_CACHE_CAPS:-}" ] || [ -n "${HF_CI_BUILDER_CONTAINER:-}" ]; then
    stamp="$HF_CI_CACHE/.cap-stamp"
    if [ "$dry" = 1 ] || [ ! -f "$stamp" ] || [ -z "$(find -P "$stamp" -mmin -"${HF_CI_CAP_CHECK_MIN:-60}" 2>/dev/null)" ]; then
      for entry in ${HF_CI_CACHE_CAPS:-}; do
        repo=${entry%%:*}; cap=${entry##*:}
        # A repo name is one plain path component: no separator, no "..".
        case "$repo" in ''|.|..|*..*|*[!A-Za-z0-9._-]*) echo " cap: bad repo name in '${entry}', skipped"; continue;; esac
        dir="$HF_CI_CACHE/$repo"
        case "$cap" in ''|*[!0-9]*) echo " cap: bad entry '${entry}', skipped"; continue;; esac
        [ -d "$dir" ] && [ ! -L "$dir" ] || { echo " cap: ${dir} missing or a symlink, skipped"; continue; }
        du_kb=$(du -sk "$dir" 2>/dev/null | awk '{ print $1 }')
        echo " cap: ${repo} cache $((${du_kb:-0} / 1048576)) GB (cap ${cap} GB)"
        if [ "${du_kb:-0}" -gt $((cap * 1048576)) ]; then
          echo " cap: ${repo} over the cap, level-1 prune of its target dirs"
          for r in "$dir"/target*; do
            hf_prune_root_ok "$r" || continue
            echo "root ${r}: cap-driven level 1"
            hf_prune_root_locked "$r" 1 "$cutoff"
          done
          echo " cap: ${repo} cache now $(( $(du -sk "$dir" 2>/dev/null | awk '{ print $1 }') / 1048576 )) GB"
        fi
      done
      hf_prune_builder "${HF_CI_BUILDER_KEEP_GB:-30}" "cap check"
      [ "$dry" = 1 ] || touch "$stamp" 2>/dev/null
    fi
  fi
  return 0
}

# Tested-tree markers (written once by CI, mtime = write time) older than
# HF_CI_TESTED_TREES_DAYS are deleted, at any depth and including the dot files
# (.tmp.*) an interrupted writer leaves behind, and the directory is created
# when missing, owned like the shared cache dir above it (the prune runs as
# root, the runners write the markers as their own user).
hf_prune_markers() {
  local dir="${HF_CI_TESTED_TREES_DIR:-$HF_CI_CACHE/shared/tested-trees}" days="${HF_CI_TESTED_TREES_DAYS:-30}" ref n kb
  # Never act through a link: not on a linked marker dir, and not on a default
  # location whose path runs through a link that leaves the cache root.
  if [ -L "$dir" ]; then echo " tested-trees: ${dir} is a symlink, skipped"; return 0; fi
  # Fail closed: whatever the value (env override included), the marker dir must
  # resolve strictly under the cache root, or nothing is created or deleted.
  hf_prune_within "$dir" "$HF_CI_CACHE" || { echo " tested-trees: ${dir} is not under the cache root, skipped"; return 0; }
  if [ ! -d "$dir" ]; then
    if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then echo " tested-trees: ${dir} missing, would create it"; return 0; fi
    ref="$HF_CI_CACHE/shared"; [ -d "$ref" ] || ref="$HF_CI_CACHE"
    mkdir -p "$dir" 2>/dev/null && chown --reference="$ref" "$dir" 2>/dev/null && chmod --reference="$ref" "$dir" 2>/dev/null
    echo " tested-trees: created ${dir}"
    return 0
  fi
  n=$(find -P "$dir" -type f -mmin +$((days * 1440)) 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt 0 ]; then
    kb=$(find -P "$dir" -type f -mmin +$((days * 1440)) -printf '%b\n' 2>/dev/null | awk '{ s += $1 } END { print int(s / 2) }')
  fi
  if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
    echo " tested-trees: would remove ${n:-0} marker(s) older than ${days} d (${dir}): $((${kb:-0} / 1024)) MB"
  else
    find -P "$dir" -type f -mmin +$((days * 1440)) -delete 2>/dev/null
    find -P "$dir" -mindepth 1 -type d -empty -mmin +$((days * 1440)) -delete 2>/dev/null
    echo " tested-trees: removed ${n:-0} marker(s) older than ${days} d (${dir})"
  fi
  return 0
}

# The whole prune. Runs as root in the detached container only. Single
# instance via a lock file in the cache root.
hf_prune_main() {
  local r lvl cutoff before after any=0 daily=0 freed_kb=0
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
  # hf_prune_apply runs in pipeline subshells, so it reports freed space through
  # this file instead of a variable.
  hf_prune_freed_file=$(mktemp 2>/dev/null) || hf_prune_freed_file=""
  echo "=== $(date -u +%FT%TZ) prune start (dry_run=${PRUNE_DRY_RUN:-0}, daily_due=${daily}) ==="
  hf_prune_rootfs "$cutoff"
  hf_prune_markers
  for r in "$HF_CI_CACHE"/*/target*; do
    [ -d "$r" ] || continue
    hf_prune_root_ok "$r" || { echo "root ${r}: symlink or outside the cache root, skipped"; continue; }
    lvl=$(hf_prune_level "$r") || { echo "root ${r}: df failed, skipped"; continue; }
    [ "$lvl" = 0 ] && [ "$daily" = 1 ] && lvl=1
    before=$(df -Pk "$r" 2>/dev/null | awk 'NR==2 { printf "%.1f", $4 / 1048576 }')
    if [ "${lvl:-0}" -lt 1 ]; then echo "root ${r}: ${before} GB free, level 0, nothing to do"; continue; fi
    any=1
    echo "root ${r}: ${before} GB free on its filesystem, level ${lvl}"
    # Race guard (test-backend.lock) lives in hf_prune_root_locked.
    hf_prune_root_locked "$r" "$lvl" "$cutoff"
    after=$(df -Pk "$r" 2>/dev/null | awk 'NR==2 { printf "%.1f", $4 / 1048576 }')
    echo " free: ${before} GB -> ${after} GB"
  done
  [ "$any" = 1 ] && hf_prune_volumes
  if [ -n "$hf_prune_freed_file" ]; then
    freed_kb=$(awk '{ s += $1 } END { print int(s) }' "$hf_prune_freed_file" 2>/dev/null)
    rm -f "$hf_prune_freed_file"; hf_prune_freed_file=""
  fi
  if [ "${PRUNE_DRY_RUN:-0}" != "1" ]; then
    touch "$HF_CI_CACHE/.prune-stamp" 2>/dev/null
    echo "=== prune done, freed ~$((${freed_kb:-0} / 1024)) MB in cargo caches ==="
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
# holds. Without docker or the image the prune is skipped, never run inline.
hf_prune_launch() {
  local image v envargs=() cgp=() script fns
  hf_prune_relaunch_ok || return 0
  hf_prune_gate || return 0
  for v in HF_CI_CACHE HF_CI_PRUNE_L1_GB HF_CI_PRUNE_L2_GB HF_CI_PRUNE_L3_GB \
           HF_CI_PRUNE_K1 HF_CI_PRUNE_K2 HF_CI_PRUNE_K3 HF_CI_PRUNE_MIN_AGE_MIN \
           HF_CI_PRUNE_TP_DAYS_L1 HF_CI_PRUNE_TP_DAYS_L2 HF_CI_PRUNE_TP_DAYS_L3 HF_CI_PRUNE_OWN \
           HF_CI_PRUNE_JUNK HF_CI_PRUNE_LEVEL PRUNE_DRY_RUN \
           HF_CI_ROOT_FLOOR_GB HF_CI_ROOT_FLOOR_COOLDOWN_MIN HF_CI_BUILDER_FLOOR_KEEP_GB \
           HF_CI_CACHE_CAPS HF_CI_CAP_CHECK_MIN HF_CI_BUILDER_KEEP_GB \
           HF_CI_BUILDER_CONTAINER HF_CI_ROOTFS_PROBE \
           HF_CI_TESTED_TREES_DIR HF_CI_TESTED_TREES_DAYS; do
    [ -n "${!v+x}" ] && envargs+=( -e "$v=${!v}" )
  done
  [ -n "${HF_CI_CGROUP_PARENT:-}" ] && cgp=( --cgroup-parent "$HF_CI_CGROUP_PARENT" )
  image="${HF_CI_PRUNE_IMAGE:-}"
  if [ -z "$image" ] && command -v docker >/dev/null 2>&1; then
    image=$(docker inspect --format '{{.Config.Image}}' "$(hostname)" 2>/dev/null)
  fi
  if [ -n "$image" ] && command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
    fns=$(declare -f hf_prune_awklib hf_prune_within hf_prune_root_ok hf_prune_level hf_prune_daily_due hf_prune_select hf_prune_select_tp \
                     hf_prune_own_stems hf_prune_atime_index hf_prune_atime_ok hf_prune_apply \
                     hf_prune_root hf_prune_volumes hf_prune_rootfs_free_kb hf_prune_on_rootfs \
                     hf_prune_rootfs_due hf_prune_root_locked hf_prune_builder hf_prune_rootfs \
                     hf_prune_markers hf_prune_main)
    script="${fns}
hf_prune_main >> \"\$HF_CI_CACHE/prune.log\" 2>&1"
    if docker run -d --rm --name hf-ci-prune --user 0:0 --entrypoint timeout \
         "${cgp[@]}" "${envargs[@]}" \
         -v "${HF_CI_CACHE}:${HF_CI_CACHE}" -v /var/run/docker.sock:/var/run/docker.sock \
         "$image" 1800 bash -c "$script" >/dev/null 2>&1
    then
      touch "$HF_CI_CACHE/.launch-stamp" 2>/dev/null
      echo "job-completed hook: cache prune started as root in the background (log: ${HF_CI_CACHE}/prune.log)"
    else
      echo "job-completed hook: cache prune already running (or docker refused); skipped"
    fi
  else
    # Never prune inline: the prune deletes by path, and it must only ever run
    # in the root sibling container (see "Cache pruning" in runner/README.md).
    echo "job-completed hook: docker or the prune image is unavailable; prune skipped"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main flow. Guarded so `source job-completed.sh` only defines the functions.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  # GUARD, before anything else. The wipe and the credential sweep below delete
  # $HOME/.ssh, $HOME/.config/gh and more: on a workstation that is the owner's
  # keys. Run only inside the CI runner container, which carries the marker
  # (HF_CI_RUNNER_CONTAINER=1, set by the image and the compose file) and
  # Docker's /.dockerenv. Anywhere else: no row, no wipe, no sweep, no prune.
  if [ "${HF_CI_RUNNER_CONTAINER:-}" != "1" ] || [ ! -e /.dockerenv ]; then
    echo "job-completed hook: refusing to run outside the CI runner container (HF_CI_RUNNER_CONTAINER/.dockerenv missing)" >&2
    exit 2
  fi
  set -u
  set +e   # the runner may invoke hooks with `bash -e`; this hook must never fail the job

  # The job's finish row goes first, so finished_at is the end of the job and
  # not the end of the wipe and prune below.
  _hf_hooks_dir="${HF_CI_HOOKS_DIR:-$(dirname -- "${BASH_SOURCE[0]}")}"
  if [ -r "$_hf_hooks_dir/job-row.sh" ]; then
    # shellcheck source=job-row.sh
    . "$_hf_hooks_dir/job-row.sh" && hf_job_row completed
  fi

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
  wipe_cgp=()
  [ -n "${HF_CI_CGROUP_PARENT:-}" ] && wipe_cgp=( --cgroup-parent "$HF_CI_CGROUP_PARENT" )

  # Depth floor, so a bad GITHUB_WORKSPACE can never wipe a top-level directory:
  # absolute, at least 3 path components, no "." or ".." component, and not the
  # prefix itself.
  ws_bad=""
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    ws_slashes=${GITHUB_WORKSPACE%/}; ws_slashes=${ws_slashes//[!\/]/}
    case "$GITHUB_WORKSPACE" in
      /*) ;;
      *) ws_bad="not an absolute path" ;;
    esac
    case "${GITHUB_WORKSPACE%/}/" in
      */../*|*/./*|*//*) ws_bad="contains ., .. or an empty path component" ;;
    esac
    [ "${#ws_slashes}" -ge 3 ] || ws_bad="fewer than 3 path components"
    [ "${GITHUB_WORKSPACE%/}" != "${RUNNER_WORK_PREFIX%/}" ] || ws_bad="equals RUNNER_WORK_PREFIX"
  fi

  if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -n "${RUNNER_WORK_PREFIX}" ] && [ -z "$ws_bad" ] && [ "${GITHUB_WORKSPACE#"$RUNNER_WORK_PREFIX"}" != "$GITHUB_WORKSPACE" ]; then
    wipe_outcome=""
    if command -v docker >/dev/null 2>&1; then
      if docker run --rm "${wipe_cgp[@]}" -v "${GITHUB_WORKSPACE}:/w" "$HOOK_WIPE_IMAGE" \
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
    echo "job-completed hook: GITHUB_WORKSPACE (${GITHUB_WORKSPACE:-unset}) not under RUNNER_WORK_PREFIX (${RUNNER_WORK_PREFIX:-unset})${ws_bad:+, or refused: $ws_bad} — skipped"
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
