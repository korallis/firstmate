#!/usr/bin/env bash
# Regression coverage for authoritative checks-green transitions that occur with
# no new status append, pane change, or agent turn.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-pr-ready-lib.sh
. "$ROOT/bin/fm-pr-ready-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ready-wake-tests)
READY_LINE='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)'
WORKING_LINE='state: working · source: run-step · ci running'
FAILED_LINE='state: failed · source: run-step · run failed'
PAUSED_GREEN_LINE='state: paused · source: status-log · awaiting upstream owner · checks green: PR ready for review (still monitoring for merge/close)'

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

make_task() {  # <dir> <id> <yolo>
  local dir=$1 id=$2 yolo=$3
  fm_git_init_commit "$dir/$id-wt"
  git -C "$dir/$id-wt" checkout -qb "fm/$id"
  fm_write_meta "$dir/state/$id.meta" \
    "window=test:fm-$id" \
    "worktree=$dir/$id-wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=$yolo"
}

next_ready() {  # <state> <fakebin> <task-id> <line>
  local state=$1 fakebin=$2 id=$3
  export FM_FAKE_CREW_STATE=$4
  FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_PR_READY_STATE_BIN
  fm_pr_ready_transition "$state" "$id" || true
}

commit_record() {  # <state> <record>
  local state=$1 record=$2 id identity rest
  IFS=$'\t' read -r id identity rest <<< "$record"
  fm_pr_ready_commit "$state" "$id" "$identity"
}

test_background_ci_fixer_wakes_before_stale_status() {
  local dir state fakebin out pid drain key pane_hash
  dir=$(make_case background-ci-fixer); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" sr-m7 on
  printf 'blocked: two CI checks failed before the autonomous fixer resumed\n' > "$state/sr-m7.status"
  printf '%s' "$(seen_sig "$state/sr-m7.status")" > "$state/.seen-sr-m7_status"
  printf 'unchanged idle pane\n' > "$dir/pane"
  key=$(printf '%s' 'test:fm-sr-m7' | tr ':/.' '___')
  pane_hash=$(hash_text 'unchanged idle pane')
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '2\n' > "$state/.count-$key"
  date +%s > "$state/.stale-since-$key"
  export FM_FAKE_TMUX_CAPTURE="$dir/pane"
  export FM_FAKE_CREW_STATE="$READY_LINE"
  export FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_SCAN_INTERVAL=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 50 || fail "watcher did not wake for background checks-green transition"
  grep -F "check: authoritative PR-ready transition for sr-m7" "$out" >/dev/null \
    || fail "watcher did not emit the authoritative PR-ready reason"
  grep -F "automatic approval recorded" "$out" >/dev/null \
    || fail "automatic-approval posture was not preserved for Firstmate"
  grep -F "stale:" "$out" >/dev/null && fail "stale pane handling outran the authoritative PR-ready wake"
  drain="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain" 2>/dev/null \
    || fail "wake drain failed after PR-ready transition"
  grep "$(printf '\tcheck\tpr-ready:sr-m7\t')" "$drain" >/dev/null \
    || fail "PR-ready transition was not durably queued as actionable"
  [ -s "$state/.pr-ready-sr-m7" ] || fail "PR-ready dedupe marker was not committed after enqueue"
  pass "background CI-fixer success wakes before an idle pane or stale blocker can mask it"
}

test_duplicate_suppression_across_watcher_generations() {
  local dir state fakebin first second
  dir=$(make_case watcher-generations); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" generation off
  first=$(next_ready "$state" "$fakebin" generation "$READY_LINE")
  [ -n "$first" ] || fail "first watcher generation missed ready transition"
  commit_record "$state" "$first"
  second=$(FM_STATE_OVERRIDE="$state" FM_FAKE_CREW_STATE="$READY_LINE" \
    FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '. "$1"; fm_pr_ready_transition "$2" generation || true' _ "$ROOT/bin/fm-pr-ready-lib.sh" "$state")
  [ -z "$second" ] || fail "second watcher generation duplicated the same readiness identity"
  pass "persistent readiness identity suppresses duplicates across watcher generations"
}

test_relapse_rearm_and_head_change_supersede_green() {
  local dir state fakebin first again marker
  dir=$(make_case relapse-rearm); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" relapse off
  first=$(next_ready "$state" "$fakebin" relapse "$READY_LINE")
  commit_record "$state" "$first"
  marker="$state/.pr-ready-relapse"

  [ -z "$(next_ready "$state" "$fakebin" relapse "$WORKING_LINE")" ] || fail "active re-arm emitted a ready transition"
  [ ! -e "$marker" ] || fail "active re-arm did not supersede the prior green marker"
  again=$(next_ready "$state" "$fakebin" relapse "$READY_LINE")
  [ -n "$again" ] || fail "green after re-arm did not re-surface"
  commit_record "$state" "$again"

  [ -z "$(next_ready "$state" "$fakebin" relapse "$FAILED_LINE")" ] || fail "failed checks emitted a ready transition"
  [ ! -e "$marker" ] || fail "failed checks did not supersede the prior green marker"
  again=$(next_ready "$state" "$fakebin" relapse "$READY_LINE")
  [ -n "$again" ] || fail "green after failed checks did not re-surface"
  commit_record "$state" "$again"

  printf 'post-fix\n' >> "$dir/relapse-wt/README.md"
  git -C "$dir/relapse-wt" add README.md
  git -C "$dir/relapse-wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'ci fixer head'
  again=$(next_ready "$state" "$fakebin" relapse "$READY_LINE")
  [ -n "$again" ] || fail "new green head was suppressed by the prior-head marker"
  pass "re-arm, failed checks, and a CI-fixer head change supersede prior green readiness"
}

test_approval_posture_changes_reason_not_authority() {
  local dir state fakebin first second
  dir=$(make_case approval-posture); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" auto on
  make_task "$dir" ordinary off
  first=$(next_ready "$state" "$fakebin" auto "$READY_LINE")
  printf '%s' "$first" | grep -F "automatic approval recorded" >/dev/null \
    || fail "automatic-approval task did not carry the internal posture hint"
  printf '%s' "$first" | grep -F "normal recorded review/merge path" >/dev/null \
    || fail "automatic-approval hint bypassed the recorded review/merge path"
  commit_record "$state" "$first"
  second=$(next_ready "$state" "$fakebin" ordinary "$READY_LINE")
  printf '%s' "$second" | grep -F "captain approval required" >/dev/null \
    || fail "ordinary task did not preserve captain approval authority"
  printf '%s' "$second" | grep -F "normal recorded PR-review path" >/dev/null \
    || fail "ordinary task did not preserve the recorded review path"
  pass "approval on/off changes only the actionable hint; the shell never approves or merges"
}

test_keyed_pause_precedence_and_stale_absorption() {
  local dir state fakebin out pid key record
  dir=$(make_case keyed-pause); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" paused off
  record=$(next_ready "$state" "$fakebin" paused "$READY_LINE")
  commit_record "$state" "$record"
  [ -z "$(next_ready "$state" "$fakebin" paused "$PAUSED_GREEN_LINE")" ] \
    || fail "current keyed pause was mistaken for PR-ready"
  [ ! -e "$state/.pr-ready-paused" ] || fail "current keyed pause did not supersede the green marker"

  printf 'paused [key=upstream-owner]: awaiting the upstream owner\n' > "$state/paused.status"
  printf '%s' "$(seen_sig "$state/paused.status")" > "$state/.seen-paused_status"
  printf 'unchanged paused pane\n' > "$dir/pane"
  export FM_FAKE_TMUX_CAPTURE="$dir/pane"
  export FM_FAKE_CREW_STATE="$PAUSED_GREEN_LINE"
  export FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_SCAN_INTERVAL=0 \
    FM_PAUSE_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 2.5
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; fail "keyed pause produced an actionable wake"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "keyed pause printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "keyed pause queued a PR-ready or stale wake"; }
  key=$(printf '%s' 'test:fm-paused' | tr ':/.' '___')
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "stale keyed pause did not enter bounded pause tracking"; }
  reap "$pid"
  record=$(next_ready "$state" "$fakebin" paused "$READY_LINE")
  [ -n "$record" ] || fail "resolved pause did not restore the underlying ready transition"
  pass "keyed green pauses keep pause precedence while stale, then re-surface readiness after resolution"
}

test_background_ci_fixer_wakes_before_stale_status
test_duplicate_suppression_across_watcher_generations
test_relapse_rearm_and_head_change_supersede_green
test_approval_posture_changes_reason_not_authority
test_keyed_pause_precedence_and_stale_absorption
printf 'all fm-pr-ready wake tests passed\n'
