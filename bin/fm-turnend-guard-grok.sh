#!/usr/bin/env bash
# Grok Stop-hook adapter for the firstmate PRIMARY turn-end guard.
#
# Grok Stop hooks are passive: exit 2 does not block or feed stderr back to the
# model. This adapter still uses the shared primary-scoped predicate in
# fm-turnend-guard.sh.
#
# DO NOT spawn headless `grok --resume -p ...` as a "forced follow-up".
# Empirical failure (2026-07-11, session 019f4c6c): dozens of hung headless
# resumes accumulated for hours, stdout was discarded, and none of them injected
# into the interactive TUI - so the captain saw silence while supervision stayed
# off. Protocol docs already warn that headless `grok -p` is not a reliable
# primary host.
#
# When the predicate says the primary would end blind, this adapter:
# 1. Writes a durable gap marker under the operational home's state/
# 2. Mechanically ensures this home's watcher is running (detached, singleton)
# 3. Never spawns grok, and always exits 0 (passive hook contract)
#
# The interactive TUI still MUST arm `bin/fm-watch-arm.sh` as its own tracked
# background task for background-notify wakes. This adapter only prevents a
# total watcher outage and stops the zombie-resume storm.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Legacy loop-guard env (kept so older nested resumes die immediately).
[ -n "${GROK_TURNEND_GUARD_ACTIVE:-}" ] && exit 0

ROOT=${GROK_WORKSPACE_ROOT:-${CLAUDE_PROJECT_DIR:-}}
[ -n "$ROOT" ] || exit 0
ROOT=${ROOT%/}
[ -x "$ROOT/bin/fm-turnend-guard.sh" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-turnend-grok.XXXXXX") || exit 0
cleanup() {
  rm -f "$ERR" 2>/dev/null || true
  if [ -n "${ENSURE_LOCK:-}" ]; then
    rmdir "$ENSURE_LOCK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

printf '%s' "$PAYLOAD" | "$ROOT/bin/fm-turnend-guard.sh" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] || exit 0

REASON=$(cat "$ERR" 2>/dev/null || true)
[ -n "$REASON" ] || REASON='tasks in flight, no live watcher - resume supervision according to the session-start operating block before ending the turn'

# Operational home: prefer FM_HOME (fleet state), else the workspace root.
FM_HOME_EFF="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME_EFF/state}"
mkdir -p "$STATE" 2>/dev/null || true

# Prefer ops-home bin when present so watcher matches the live fleet scripts.
WATCH="$ROOT/bin/fm-watch.sh"
[ -x "$FM_HOME_EFF/bin/fm-watch.sh" ] && WATCH="$FM_HOME_EFF/bin/fm-watch.sh"
SCRIPT_DIR="$(cd "$(dirname "$WATCH")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" 2>/dev/null || exit 0

GRACE=${FM_GUARD_GRACE:-300}

{
  date -u +%Y-%m-%dT%H:%M:%SZ
  printf '%s\n' "$REASON"
} >"$STATE/.supervision-gap" 2>/dev/null || true

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME_EFF" 2>/dev/null; then
  exit 0
fi

# Single-flight ensure: never stampede concurrent Stop hooks.
ENSURE_LOCK="$STATE/.turnend-watch-ensure.lock"
if ! mkdir "$ENSURE_LOCK" 2>/dev/null; then
  exit 0
fi

LOG="$STATE/.turnend-watch-ensure.log"
(
  export FM_HOME="$FM_HOME_EFF"
  export FM_STATE_OVERRIDE="$STATE"
  cd "$FM_HOME_EFF" 2>/dev/null || cd "$ROOT" || exit 0
  # Detached: Stop-hook exit must not kill the watcher. fm-watch.sh owns its
  # singleton lock and self-evicts duplicates.
  nohup "$WATCH" >>"$LOG" 2>&1 &
) || true

# Brief confirm only - never hold the Stop hook for long.
i=0
while [ "$i" -lt 25 ]; do
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME_EFF" 2>/dev/null; then
    exit 0
  fi
  sleep 0.2
  i=$((i + 1))
done

exit 0
