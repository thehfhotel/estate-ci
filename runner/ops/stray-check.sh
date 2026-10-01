#!/usr/bin/env bash
# Nightly stray check (run it from the host's cron, as a user that can use the
# docker socket). Lists RUNNING containers that belong to CI but are NOT in the
# CI cgroup slice, i.e. containers that a job started as a sibling of production
# containers and that therefore escape the CPU / memory / IO limits placed on
# the slice (ADR 0002 decision 10, plan item A5).
#
# Report-only by default: one block per run appended to a log, nothing else.
# Alerting is a flag, off until the owner turns it on (plan item D3).
#
# What counts as a CI container (any one of these):
#   label    a label KEY that matches HF_CI_STRAY_LABEL_RE. The Actions runner
#            stamps every job, service and container-action container it creates
#            with one bare label whose key is a 6-hex-char hash of the runner's
#            install directory, so each runner has its own value.
#   network  attached to a network matching one of the globs in
#            HF_CI_STRAY_NETWORKS. The runner creates github_network_<id> for
#            every job that uses `container:` or `services:`. Containers that a
#            job starts by hand with `docker run` carry no label, so add the
#            compose network the runners themselves sit on, which such
#            containers usually join.
#   name     container name matches HF_CI_STRAY_NAME_RE (runner, builder and
#            prune containers).
#   mount    a bind-mount source starts with one of HF_CI_STRAY_PATHS (space
#            separated prefixes: the runner work dirs, the cache root).
#
# A CI container is "inside" when HostConfig.CgroupParent equals HF_CI_SLICE or
# names a child slice of it (hf-ci-<x>.slice). With the systemd cgroup driver
# the value is a slice name (hf-ci.slice); with the cgroupfs driver it is a path
# (/hf-ci), so set HF_CI_SLICE to match `docker info` (the header line of every
# report records the driver). Until the slice exists and runner, builder and job
# containers are configured to join it, EVERY CI container is reported.
#
# Knobs (env vars, or lines of VAR=value in the file named by HF_CI_STRAY_ENV):
#   HF_CI_SLICE=hf-ci.slice          expected cgroup parent
#   HF_CI_STRAY_LOG=<file>           append the report here (unset: stdout only;
#                                    the file is trimmed to its last 2000 lines
#                                    past 1 MB)
#   HF_CI_STRAY_LABEL_RE='^[0-9a-f]{6}$'
#   HF_CI_STRAY_NETWORKS='github_network_*'
#   HF_CI_STRAY_NAME_RE='^hf-ci-'
#   HF_CI_STRAY_PATHS=''
#   HF_CI_STRAY_ALERT=0              1 = also pipe the report of a run that
#                                    found strays to HF_CI_STRAY_ALERT_CMD
#   HF_CI_STRAY_ALERT_CMD=''         command (run through `bash -c`) reading the
#                                    report on stdin; nothing is wired by default
#
# Exits 0 whenever the check ran, so cron stays quiet; a docker failure exits 2
# and is logged.

set -u

if [ -n "${HF_CI_STRAY_ENV:-}" ] && [ -r "$HF_CI_STRAY_ENV" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$HF_CI_STRAY_ENV"
  set +a
fi

slice="${HF_CI_SLICE:-hf-ci.slice}"
label_re="${HF_CI_STRAY_LABEL_RE:-}"
[ -n "$label_re" ] || label_re='^[0-9a-f]{6}$'   # not as a ${..:-default}: the } of {6} would end the expansion
networks="${HF_CI_STRAY_NETWORKS:-github_network_*}"
name_re="${HF_CI_STRAY_NAME_RE:-^hf-ci-}"
paths="${HF_CI_STRAY_PATHS:-}"
log="${HF_CI_STRAY_LOG:-}"
alert="${HF_CI_STRAY_ALERT:-0}"
alert_cmd="${HF_CI_STRAY_ALERT_CMD:-}"
ts=$(date -u +%FT%TZ)

emit() { if [ -n "$log" ]; then printf '%s\n' "$1" >> "$log" 2>/dev/null; fi; printf '%s\n' "$1"; }

if ! info=$(docker info --format '{{.CgroupDriver}} v{{.CgroupVersion}}' 2>/dev/null); then
  emit "${ts} stray-check: docker unavailable"
  exit 2
fi

ids=$(docker ps -q --no-trunc 2>/dev/null)
report=""
running=0; ci=0; outside=0
base=${slice%.slice}
if [ -n "$ids" ]; then
  # One inspect call for every container; fields are separated by the ASCII unit
  # separator (a tab would collapse empty fields) and the label, network and
  # mount lists are space separated (none of those values contain a space in
  # practice, and label VALUES are not listed).
  # shellcheck disable=SC2086
  while IFS=$'\037' read -r id name cgp labels nets mounts started; do
    running=$((running + 1))
    name=${name#/}
    why=""
    for l in $labels; do
      if [[ $l =~ $label_re ]]; then why="${why}label:${l} "; fi
    done
    for n in $nets; do
      for g in $networks; do
        # shellcheck disable=SC2254
        case "$n" in $g) why="${why}network:${n} ";; esac
      done
    done
    if [ -n "$name_re" ] && [[ $name =~ $name_re ]]; then why="${why}name "; fi
    for m in $mounts; do
      for p in $paths; do
        case "$m" in "$p"*) why="${why}mount:${p} "; break 2;; esac
      done
    done
    [ -n "$why" ] || continue
    ci=$((ci + 1))
    case "$cgp" in
      "$slice"|"${base}-"*.slice) continue ;;
    esac
    outside=$((outside + 1))
    report="${report}  OUTSIDE ${name} id=${id:0:12} cgroup_parent='${cgp}' started=${started} why=${why% }"$'\n'
  done < <(docker inspect --format '{{.Id}}{{"\x1f"}}{{.Name}}{{"\x1f"}}{{.HostConfig.CgroupParent}}{{"\x1f"}}{{range $k, $v := .Config.Labels}}{{$k}} {{end}}{{"\x1f"}}{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}{{"\x1f"}}{{range .Mounts}}{{.Source}} {{end}}{{"\x1f"}}{{.State.StartedAt}}' $ids 2>/dev/null)
fi

out="${ts} stray-check: cgroup_driver=${info} expected_slice=${slice} running=${running} ci=${ci} outside_slice=${outside} alert=$([ "$alert" = 1 ] && echo on || echo off)"
[ -n "$report" ] && out="${out}"$'\n'"${report%$'\n'}"
emit "$out"

if [ -n "$log" ] && [ -f "$log" ] && [ "$(wc -c < "$log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  # In place (the log may sit in a directory this user cannot write to).
  tail -n 2000 "$log" > "${TMPDIR:-/tmp}/stray-check.$$" 2>/dev/null && cat "${TMPDIR:-/tmp}/stray-check.$$" > "$log" 2>/dev/null
  rm -f "${TMPDIR:-/tmp}/stray-check.$$"
fi

if [ "$alert" = 1 ] && [ "$outside" -gt 0 ] && [ -n "$alert_cmd" ]; then
  printf '%s\n' "$out" | bash -c "$alert_cmd" >/dev/null 2>&1 || true
fi
exit 0
