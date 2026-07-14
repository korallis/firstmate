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
# state clears the marker so a later green state re-surfaces.
# An unknown/unreadable state preserves it rather than manufacturing a duplicate
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

fm_pr_ready_scan_path() {  # <state> <task-id>
  local key
  key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s/.last-pr-ready-%s' "$1" "$key"
}

fm_pr_ready_cleanup() {  # <state> <task-id>
  rm -f "$(fm_pr_ready_marker_path "$1" "$2")" "$(fm_pr_ready_scan_path "$1" "$2")"
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
  local meta=$1 line=$2 wt branch head authority
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
    printf '|%s' "$authority"
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

fm_pr_ready_adds_relapse() {  # <prior-components> <current-components>
  local prior=$1 remaining=$2 item
  while [ -n "$remaining" ]; do
    item=${remaining%%|*}
    if [ "$remaining" = "$item" ]; then remaining=; else remaining=${remaining#*|}; fi
    case "$item" in
      relapse-*)
        fm_pr_ready_components_subset "$item" "$prior" || return 0
        ;;
    esac
  done
  return 1
}

fm_pr_ready_identity_relation() {  # <prior> <current>
  local prior=$1 current=$2 prior_rest current_rest prior_branch current_branch
  local prior_head current_head prior_components current_components
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
  if fm_pr_ready_components_subset "$prior_components" "$current_components"; then
    if fm_pr_ready_components_subset "$current_components" "$prior_components"; then
      printf 'same'
    elif fm_pr_ready_adds_relapse "$prior_components" "$current_components"; then
      printf 'different'
    else
      printf 'upgrade'
    fi
  elif fm_pr_ready_components_subset "$current_components" "$prior_components"; then
    printf 'same'
  else
    printf 'different'
  fi
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
  local state=$1 id=$2 meta kind mode yolo line verdict marker identity prior relation
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
      identity=$(fm_pr_ready_identity "$meta" "$line") || return 1
      prior=$(cat "$marker" 2>/dev/null || true)
      relation=$(fm_pr_ready_identity_relation "$prior" "$identity")
      case "$relation" in
        same) return 1 ;;
        upgrade)
          fm_pr_ready_commit "$state" "$id" "$identity"
          return 1
          ;;
      esac
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
