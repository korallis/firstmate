#!/usr/bin/env bash
# Persistent authoritative PR-readiness transition detection for fm-watch.sh.
#
# fm-crew-state.sh remains the single owner of branch-matched no-mistakes state.
# This library periodically reads that state during the watcher's bounded task
# scan, classifies only `done + run-step + checks green: PR ready for review` as
# ready, and returns one actionable transition record at a time.
#
# A per-task state/.pr-ready-<id> marker suppresses the same readiness identity
# across watcher generations.
# The identity combines branch and HEAD with fm-crew-state's stable run/CI-monitor
# generation, never volatile rendered current-state detail.
# Any observed authoritative re-arm, failed check, pause, gate, or other non-ready
# state records persistent supersession and clears the marker so a later green
# state re-surfaces, including after a watcher restart.
# Newly readable history only refines an existing marker; it never substitutes
# identity-string inference for an observed supersession.
# An unknown/unreadable state preserves readiness rather than manufacturing a
# duplicate from a transient read error.
#
# The watcher must enqueue before calling fm_pr_ready_commit. This library never
# merges, approves, invokes GitHub, answers ask-user findings, or makes a safety
# decision. It only reports the recorded approval posture in the internal wake so
# Firstmate can choose the existing recorded review/merge path.

_FM_PR_READY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PR_READY_LIB_DIR="."
FM_PR_READY_STATE_BIN="${FM_PR_READY_STATE_BIN:-${FM_CREW_STATE_BIN:-$_FM_PR_READY_LIB_DIR/fm-crew-state.sh}}"

fm_pr_ready_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_pr_ready_marker_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.pr-ready-%s' "$1" "$key"
}

fm_pr_ready_scan_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.last-pr-ready-%s' "$1" "$key"
}

fm_pr_ready_superseded_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.pr-ready-superseded-%s' "$1" "$key"
}

fm_pr_ready_status_surfaced_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.pr-ready-status-surfaced-%s' "$1" "$key"
}

fm_pr_ready_observed_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.pr-ready-observed-%s' "$1" "$key"
}

fm_pr_ready_cleanup() {  # <state> <task-id>
  rm -f "$(fm_pr_ready_marker_path "$1" "$2")" \
    "$(fm_pr_ready_scan_path "$1" "$2")" \
    "$(fm_pr_ready_superseded_path "$1" "$2")" \
    "$(fm_pr_ready_status_surfaced_path "$1" "$2")" \
    "$(fm_pr_ready_observed_path "$1" "$2")"
}

# Print ready, supersede, or indeterminate for one canonical crew-state line.
fm_pr_ready_verdict() {  # <crew-state-line>
  local line=$1 state source
  case "$line" in state:*) ;; *) printf 'indeterminate'; return ;; esac
  state=${line#state: }
  state=${state%% *}
  case "$line" in *'source: '*) source=${line#*source: }; source=${source%% *} ;; *) source=none ;; esac
  if [ "$state" = "done" ]; then
    case "$source:$line" in
      run-step:*'checks green: PR ready for review'*|status-log:*'checks green'*'run still monitoring PR'*)
        printf 'ready'
        return
        ;;
    esac
  fi
  case "$state" in
    working|parked|blocked|paused|done|failed) printf 'supersede' ;;
    *) printf 'indeterminate' ;;
  esac
}

fm_pr_ready_identity() {  # <meta> <crew-state-line>
  local meta=$1 line=$2 wt branch head authority run details item
  wt=$(fm_pr_ready_meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] && [ -n "$head" ] || return 1
  case "$line" in
    *'run-identity: '*)
      authority=${line#*run-identity: }
      authority=${authority%% *}
      ;;
  esac
  printf '%s|%s' "$branch" "$head"
  if [ -n "${authority:-}" ]; then
    run=${authority%%|*}
    printf '|run=%s' "$run"
    if [ "$authority" != "$run" ]; then
      details=${authority#*|}
      while [ -n "$details" ]; do
        item=${details%%|*}
        printf '|detail=%s' "$item"
        if [ "$details" = "$item" ]; then details=; else details=${details#*|}; fi
      done
    fi
  fi
}

fm_pr_ready_components_subset() {  # <candidate-subset> <candidate-superset>
  local remaining=$1 superset=$2 candidates item candidate found
  [ -z "$remaining" ] && return 0
  while [ -n "$remaining" ]; do
    item=${remaining%%|*}
    if [ "$remaining" = "$item" ]; then remaining=; else remaining=${remaining#*|}; fi
    candidates=$superset
    found=1
    while [ -n "$candidates" ]; do
      candidate=${candidates%%|*}
      if [ "$candidates" = "$candidate" ]; then candidates=; else candidates=${candidates#*|}; fi
      if [ "$item" = "$candidate" ]; then
        found=0
        break
      fi
    done
    [ "$found" -eq 0 ] || return 1
  done
}

fm_pr_ready_identity_component() {  # <identity> <prefix>
  local components item
  components=$1
  while [ -n "$components" ]; do
    item=${components%%|*}
    case "$item" in "$2"*) printf '%s' "${item#"$2"}"; return 0 ;; esac
    if [ "$components" = "$item" ]; then components=; else components=${components#*|}; fi
  done
  return 1
}

fm_pr_ready_now_ms() {
  local seconds fraction
  if [ -n "${EPOCHREALTIME:-}" ]; then
    seconds=${EPOCHREALTIME%%.*}
    fraction=${EPOCHREALTIME#*.}000
    printf '%s%s' "$seconds" "${fraction:0:3}"
  else
    printf '%s000' "$(date +%s)"
  fi
}

fm_pr_ready_file_ms() {  # <path>
  local seconds value fraction
  if [ "$(uname)" = Darwin ]; then
    value=$(stat -f %Fm "$1" 2>/dev/null) || return 1
    seconds=${value%%.*}
    fraction=${value#*.}000
  else
    seconds=$(stat -c %Y "$1" 2>/dev/null) || return 1
    value=$(stat -c %y "$1" 2>/dev/null) || return 1
    case "$value" in *.*) fraction=${value#*.}; fraction=${fraction%% *}000 ;; *) fraction=000 ;; esac
  fi
  case "$seconds:$fraction" in *[!0-9:]*|:*) return 1 ;; esac
  printf '%s%s' "$seconds" "${fraction:0:3}"
}

fm_pr_ready_status_event_ms() {  # <state> <task-id>
  fm_pr_ready_file_ms "$1/$2.status" 2>/dev/null || fm_pr_ready_now_ms
}

fm_pr_ready_run_ms() {  # <run-id>
  local value=0 chars char digit i
  chars=${1%%-*}
  [ "${#chars}" -ge 10 ] || return 1
  chars=${chars:0:10}
  i=0
  while [ "$i" -lt 10 ]; do
    char=${chars:$i:1}
    case "$char" in
      0|O) digit=0 ;; 1|I|L) digit=1 ;; 2) digit=2 ;; 3) digit=3 ;;
      4) digit=4 ;; 5) digit=5 ;; 6) digit=6 ;; 7) digit=7 ;;
      8) digit=8 ;; 9) digit=9 ;; A|a) digit=10 ;; B|b) digit=11 ;;
      C|c) digit=12 ;; D|d) digit=13 ;; E|e) digit=14 ;; F|f) digit=15 ;;
      G|g) digit=16 ;; H|h) digit=17 ;; J|j) digit=18 ;; K|k) digit=19 ;;
      M|m) digit=20 ;; N|n) digit=21 ;; P|p) digit=22 ;; Q|q) digit=23 ;;
      R|r) digit=24 ;; S|s) digit=25 ;; T|t) digit=26 ;; V|v) digit=27 ;;
      W|w) digit=28 ;; X|x) digit=29 ;; Y|y) digit=30 ;; Z|z) digit=31 ;;
      *) return 1 ;;
    esac
    value=$((value * 32 + digit))
    i=$((i + 1))
  done
  [ "$value" -le 281474976710655 ] || return 1
  printf '%s' "$value"
}

fm_pr_ready_run_after() {  # <run-id> <observed-ms>
  local run_ms
  run_ms=$(fm_pr_ready_run_ms "$1") || return 1
  [ "$run_ms" -gt "$2" ]
}

fm_pr_ready_identity_relation() {  # <prior> <current> [<observed-ms>]
  local prior=$1 current=$2 observed_ms=${3:-} prior_rest current_rest prior_branch current_branch
  local prior_head current_head prior_components current_components prior_run current_run
  if [ "$prior" = "$current" ]; then
    printf 'same'
    return
  fi
  case "$prior:$current" in
    *'|'*:*'|'*) ;;
    *) printf 'different'; return ;;
  esac
  prior_branch=${prior%%|*}
  current_branch=${current%%|*}
  prior_rest=${prior#*|}
  current_rest=${current#*|}
  prior_head=${prior_rest%%|*}
  current_head=${current_rest%%|*}
  [ "$prior_branch" = "$current_branch" ] && [ "$prior_head" = "$current_head" ] \
    || { printf 'different'; return; }
  case "$prior_rest" in *'|'*) prior_components=${prior_rest#*|} ;; *) prior_components= ;; esac
  case "$current_rest" in *'|'*) current_components=${current_rest#*|} ;; *) current_components= ;; esac
  prior_run=$(fm_pr_ready_identity_component "$prior_components" 'run=' || true)
  current_run=$(fm_pr_ready_identity_component "$current_components" 'run=' || true)
  if [ -n "$prior_run" ] && [ -n "$current_run" ] && [ "$prior_run" != "$current_run" ]; then
    printf 'different'
  elif [ -z "$prior_run" ] && [ -n "$current_run" ] && [ -n "$observed_ms" ] \
    && fm_pr_ready_run_after "$current_run" "$observed_ms"; then
    printf 'different'
  elif fm_pr_ready_components_subset "$current_components" "$prior_components"; then
    printf 'same'
  else
    printf 'upgrade'
  fi
}

fm_pr_ready_mark_status_surfaced() {  # <state> <task-id> <meta> <crew-state-line> [<event-ms>]
  local path tmp wt branch head authority run observed_ms
  path=$(fm_pr_ready_status_surfaced_path "$1" "$2")
  tmp="$path.tmp.${BASHPID:-$$}"
  wt=$(fm_pr_ready_meta_value "$3" worktree)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true)
  case "$4" in
    *'run-identity: '*)
      authority=${4#*run-identity: }
      authority=${authority%% *}
      run=${authority%%|*}
      ;;
  esac
  observed_ms=${5:-$(fm_pr_ready_status_event_ms "$1" "$2")}
  {
    printf 'observed_ms=%s\n' "$observed_ms"
    printf 'branch=%s\n' "$branch"
    printf 'head=%s\n' "$head"
    printf 'run=%s\n' "${run:-}"
  } > "$tmp" && mv -f "$tmp" "$path"
}

fm_pr_ready_surfaced_relation() {  # <surfaced-path> <current-identity>
  local path=$1 current=$2 observed branch head run current_branch current_rest current_head components current_run
  observed=$(fm_pr_ready_meta_value "$path" observed_ms)
  branch=$(fm_pr_ready_meta_value "$path" branch)
  head=$(fm_pr_ready_meta_value "$path" head)
  run=$(fm_pr_ready_meta_value "$path" run)
  current_branch=${current%%|*}
  current_rest=${current#*|}
  current_head=${current_rest%%|*}
  case "$current_rest" in *'|'*) components=${current_rest#*|} ;; *) components= ;; esac
  current_run=$(fm_pr_ready_identity_component "$components" 'run=' || true)
  if { [ -n "$branch" ] && [ "$branch" != "$current_branch" ]; } \
    || { [ -n "$head" ] && [ "$head" != "$current_head" ]; } \
    || { [ -n "$run" ] && [ -n "$current_run" ] && [ "$run" != "$current_run" ]; } \
    || { [ -z "$run" ] && [ -n "$current_run" ] && [ -n "$observed" ] \
      && fm_pr_ready_run_after "$current_run" "$observed"; }; then
    printf 'different'
  else
    printf 'upgrade'
  fi
}

fm_pr_ready_mark_superseded() {  # <state> <task-id> <prior-identity>
  local state=$1 path tmp observed_at
  path=$(fm_pr_ready_superseded_path "$state" "$2")
  tmp="$path.tmp.${BASHPID:-$$}"
  observed_at=$(date +%s)
  printf '%s\t%s\n' "$observed_at" "$3" > "$tmp" && mv -f "$tmp" "$path"
}

fm_pr_ready_record_supersession() {  # <state> <task-id>
  local state=$1 id=$2 marker prior
  marker=$(fm_pr_ready_marker_path "$state" "$id")
  prior=$(cat "$marker" 2>/dev/null || true)
  if [ -n "$prior" ]; then
    fm_pr_ready_mark_superseded "$state" "$id" "$prior" || return 1
    rm -f "$marker" "$(fm_pr_ready_observed_path "$state" "$id")"
  fi
  rm -f "$(fm_pr_ready_status_surfaced_path "$state" "$id")"
}

fm_pr_ready_status_reports_ready() {  # <status-line>
  local line=$1 verb
  verb=${line%%:*}
  verb=${verb%%\[key=*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  [ "$verb" = "done" ] || return 1
  case "$line" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
  esac
  return 1
}

fm_pr_ready_reason() {  # <task-id> <yolo>
  if [ "$2" = on ]; then
    printf 'check: authoritative PR-ready transition for %s (automatic approval recorded; Firstmate must use the normal recorded review/merge path and retain every safety and ask-user gate)' "$1"
  else
    printf 'check: authoritative PR-ready transition for %s (captain approval required; Firstmate must use the normal recorded PR-review path)' "$1"
  fi
}

# Print one TAB-separated "<id>\t<identity>\t<reason>" transition, or nothing.
# A non-ready authoritative observation clears the task's prior green marker.
fm_pr_ready_transition() {  # <state> <task-id>
  local state=$1 id=$2 meta kind mode yolo line verdict marker identity prior relation superseded surfaced observed
  meta="$state/$id.meta"
  [ -e "$meta" ] || return 1
  kind=$(fm_pr_ready_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 1
  mode=$(fm_pr_ready_meta_value "$meta" mode)
  [ -n "$mode" ] || mode=no-mistakes
  [ "$mode" = no-mistakes ] || return 1
  marker=$(fm_pr_ready_marker_path "$state" "$id")
  superseded=$(fm_pr_ready_superseded_path "$state" "$id")
  surfaced=$(fm_pr_ready_status_surfaced_path "$state" "$id")
  line=$(FM_STATE_OVERRIDE="$state" "$FM_PR_READY_STATE_BIN" "$id" 2>/dev/null | head -1) || true
  verdict=$(fm_pr_ready_verdict "$line")
  case "$verdict" in
    supersede)
      fm_pr_ready_record_supersession "$state" "$id" || return 1
      return 1
      ;;
    ready)
      identity=$(fm_pr_ready_identity "$meta" "$line") || return 1
      if [ -e "$surfaced" ]; then
        relation=$(fm_pr_ready_surfaced_relation "$surfaced" "$identity")
        if [ "$relation" = upgrade ]; then
          fm_pr_ready_commit "$state" "$id" "$identity"
          return 1
        fi
        rm -f "$surfaced"
      fi
      prior=$(cat "$marker" 2>/dev/null || true)
      if [ ! -e "$superseded" ]; then
        observed=$(cat "$(fm_pr_ready_observed_path "$state" "$id")" 2>/dev/null || true)
        relation=$(fm_pr_ready_identity_relation "$prior" "$identity" "$observed")
        case "$relation" in
          same) return 1 ;;
          upgrade)
            fm_pr_ready_commit "$state" "$id" "$identity"
            return 1
            ;;
        esac
      fi
      yolo=$(fm_pr_ready_meta_value "$meta" yolo)
      [ "$yolo" = on ] || yolo=off
      printf '%s\t%s\t%s\n' "$id" "$identity" "$(fm_pr_ready_reason "$id" "$yolo")"
      return 0
      ;;
  esac
  return 1
}

fm_pr_ready_seed_status_signal() {  # <state> <task-id>
  local state=$1 id=$2 meta kind mode marker superseded surfaced line verdict identity relation event_ms
  meta="$state/$id.meta"
  [ -e "$meta" ] || return 1
  kind=$(fm_pr_ready_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 1
  mode=$(fm_pr_ready_meta_value "$meta" mode)
  [ -n "$mode" ] || mode=no-mistakes
  [ "$mode" = no-mistakes ] || return 1
  marker=$(fm_pr_ready_marker_path "$state" "$id")
  superseded=$(fm_pr_ready_superseded_path "$state" "$id")
  surfaced=$(fm_pr_ready_status_surfaced_path "$state" "$id")
  event_ms=$(fm_pr_ready_status_event_ms "$state" "$id")
  line=$(FM_STATE_OVERRIDE="$state" "$FM_PR_READY_STATE_BIN" "$id" 2>/dev/null | head -1) || true
  verdict=$(fm_pr_ready_verdict "$line")
  case "$verdict" in
    supersede)
      fm_pr_ready_record_supersession "$state" "$id" || return 1
      return 1
      ;;
    ready)
      [ ! -e "$superseded" ] || return 1
      identity=$(fm_pr_ready_identity "$meta" "$line") || {
        fm_pr_ready_mark_status_surfaced "$state" "$id" "$meta" "$line" "$event_ms"
        return 0
      }
      fm_pr_ready_mark_status_surfaced "$state" "$id" "$meta" "$line" "$event_ms" || return 1
      relation=$(fm_pr_ready_surfaced_relation "$surfaced" "$identity")
      if [ "$relation" = upgrade ]; then
        fm_pr_ready_commit "$state" "$id" "$identity"
      fi
      return 0
      ;;
  esac
  [ ! -e "$superseded" ] || return 1
  fm_pr_ready_mark_status_surfaced "$state" "$id" "$meta" "$line" "$event_ms"
}

# Commit only after the caller durably enqueues the transition.
fm_pr_ready_commit() {  # <state> <task-id> <identity>
  local state=$1 marker observed tmp observed_tmp
  marker=$(fm_pr_ready_marker_path "$state" "$2")
  observed=$(fm_pr_ready_observed_path "$state" "$2")
  tmp="$marker.tmp.${BASHPID:-$$}"
  observed_tmp="$observed.tmp.${BASHPID:-$$}"
  printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$marker" || return 1
  printf '%s\n' "$(fm_pr_ready_now_ms)" > "$observed_tmp" && mv -f "$observed_tmp" "$observed" || return 1
  rm -f "$(fm_pr_ready_superseded_path "$state" "$2")" \
    "$(fm_pr_ready_status_surfaced_path "$state" "$2")"
}
