#!/usr/bin/env bash
# Persistent authoritative PR-readiness transition detection for fm-watch.sh.
#
# fm-crew-state.sh remains the single owner of branch-matched no-mistakes state.
# This library periodically reads that state during the watcher's bounded task
# scan, classifies only `done + run-step + checks green: PR ready for review` as
# ready, and returns one actionable transition record at a time.
#
# A per-task state/.pr-ready-<id> marker suppresses the same readiness identity
# across watcher generations. The identity is the stable branch and branch HEAD,
# never volatile rendered current-state detail. Any observed authoritative re-arm,
# failed check, pause, gate,
# or other non-ready state clears the marker so a later green state re-surfaces;
# an unknown/unreadable state preserves it rather than manufacturing a duplicate
# from a transient read error.
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

# Print ready, supersede, or indeterminate for one canonical crew-state line.
fm_pr_ready_verdict() {  # <crew-state-line>
  local line=$1 state source
  case "$line" in state:*) ;; *) printf 'indeterminate'; return ;; esac
  state=${line#state: }
  state=${state%% *}
  case "$line" in *'source: '*) source=${line#*source: }; source=${source%% *} ;; *) source=none ;; esac
  if [ "$state" = "done" ] && [ "$source" = run-step ]; then
    case "$line" in
      *'checks green: PR ready for review'*) printf 'ready'; return ;;
    esac
  fi
  case "$state" in
    working|parked|blocked|paused|done|failed) printf 'supersede' ;;
    *) printf 'indeterminate' ;;
  esac
}

fm_pr_ready_identity() {  # <meta>
  local meta=$1 wt branch head
  wt=$(fm_pr_ready_meta_value "$meta" worktree)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  printf '%s|%s' "${branch:-unknown-branch}" "${head:-unknown-head}"
}

fm_pr_ready_status_reports_ready() {  # <status-line>
  local line=$1 verb note
  verb=${line%%:*}
  verb=${verb%%\[key=*}
  verb=${verb#"${verb%%[![:space:]]*}"}
  verb=${verb%"${verb##*[![:space:]]}"}
  [ "$verb" = done ] || return 1
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
  local state=$1 id=$2 meta kind mode yolo line verdict marker identity prior
  meta="$state/$id.meta"
  [ -e "$meta" ] || return 1
  kind=$(fm_pr_ready_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 1
  mode=$(fm_pr_ready_meta_value "$meta" mode)
  [ -n "$mode" ] || mode=no-mistakes
  [ "$mode" = no-mistakes ] || return 1
  marker=$(fm_pr_ready_marker_path "$state" "$id")
  line=$(FM_STATE_OVERRIDE="$state" "$FM_PR_READY_STATE_BIN" "$id" 2>/dev/null | head -1) || true
  verdict=$(fm_pr_ready_verdict "$line")
  case "$verdict" in
    supersede)
      rm -f "$marker"
      return 1
      ;;
    ready)
      identity=$(fm_pr_ready_identity "$meta")
      prior=$(cat "$marker" 2>/dev/null || true)
      [ "$prior" = "$identity" ] && return 1
      yolo=$(fm_pr_ready_meta_value "$meta" yolo)
      [ "$yolo" = on ] || yolo=off
      printf '%s\t%s\t%s\n' "$id" "$identity" "$(fm_pr_ready_reason "$id" "$yolo")"
      return 0
      ;;
  esac
  return 1
}

# Commit only after the caller durably enqueues the transition.
fm_pr_ready_commit() {  # <state> <task-id> <identity>
  local state=$1 marker tmp
  marker=$(fm_pr_ready_marker_path "$state" "$2")
  tmp="$marker.tmp.${BASHPID:-$$}"
  printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$marker"
}
