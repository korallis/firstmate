#!/usr/bin/env bash
# fm-send-wait-lib.sh - the busy-agent wait helper for bin/fm-send.sh.
#
# Extracted so the shipped fm_send_wait_until_idle can be sourced and exercised
# directly by tests (tests/fm-send-busy-wait.test.sh) instead of a drifting copy.
# fm-send.sh sources this after fm-backend.sh (which provides
# fm_backend_busy_state) and before the send dispatch.
#
# Wait until the target agent is not busy so text is not merely queued behind a
# long shell. Backends that report unknown (tmux) skip the wait. The --key path
# never waits so Escape/C-c can interrupt a busy agent. The final
# budget-exhaustion branch fails loudly (returns 1) so the caller learns the
# steer did not land instead of delivering into a queue. RESOLUTION_TRIED, set by
# fm-send.sh's target resolver, is referenced in that error for diagnosis.
fm_send_wait_until_idle() {  # <backend> <target>
  local backend=$1 target=$2 wait_s poll_s waited state
  wait_s=${FM_SEND_BUSY_WAIT_SECS:-3600}
  poll_s=${FM_SEND_BUSY_POLL_SECS:-5}
  case "$wait_s" in ''|*[!0-9]*) wait_s=3600 ;; esac
  case "$poll_s" in ''|*[!0-9]*) poll_s=5 ;; esac
  [ "$wait_s" -gt 0 ] || return 0
  [ "$poll_s" -gt 0 ] || poll_s=5
  waited=0
  while [ "$waited" -le "$wait_s" ]; do
    state=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
    case "$state" in
      busy)
        if [ "$waited" -eq 0 ]; then
          echo "fm-send: $target is busy; waiting up to ${wait_s}s for idle before delivering text (set FM_SEND_BUSY_WAIT_SECS=0 to skip)" >&2
        elif [ $((waited % 30)) -eq 0 ]; then
          echo "fm-send: still waiting on busy $target (${waited}s/${wait_s}s)" >&2
        fi
        sleep "$poll_s"
        waited=$((waited + poll_s))
        ;;
      *)
        if [ "$waited" -gt 0 ]; then
          echo "fm-send: $target idle after ${waited}s; delivering text" >&2
        fi
        return 0
        ;;
    esac
  done
  echo "error: $target still busy after ${wait_s}s; text not sent (tried ${RESOLUTION_TRIED:-}). Interrupt the agent or raise FM_SEND_BUSY_WAIT_SECS." >&2
  return 1
}
