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
READY_LINE='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close) · run-identity: run-7|baseline'
ALT_READY_LINE='state: done · source: run-step · checks green: PR ready for review · run-identity: run-7|baseline · status-log event superseded by authoritative run'
RECOVERED_READY_LINE='state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close) · run-identity: run-7|relapse-1289303112:42'
STATUS_READY_LINE='state: done · source: status-log · done: PR https://github.com/o/r/pull/7 checks green · run still monitoring PR · run-identity: run-7'
COARSE_STATUS_READY_LINE='state: done · source: status-log · done: PR https://github.com/o/r/pull/7 checks green · run still monitoring PR'
UNKNOWN_READY_LINE='state: done · source: run-step · checks green: PR ready for review · run-identity: run-7'
REARMED_READY_LINE='state: done · source: run-step · checks green: PR ready for review · run-identity: run-8'
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

install_dynamic_crew_state() {  # <fakebin>
  cat > "$1/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "${FM_FAKE_CREW_STATE_FILE:?}"
SH
  chmod +x "$1/fm-crew-state.sh"
}

wait_for_marker_clear() {  # <marker> <pid>
  local marker=$1 pid=$2 n=0
  while [ -e "$marker" ] && [ "$n" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    n=$((n + 1))
  done
  [ ! -e "$marker" ]
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

test_volatile_ready_detail_does_not_wake_again() {
  local dir state fakebin record state_line out pid
  dir=$(make_case volatile-ready-detail); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" volatile-ready off
  record=$(next_ready "$state" "$fakebin" volatile-ready "$READY_LINE")
  commit_record "$state" "$record"
  state_line="$dir/crew-state"
  printf '%s\n' "$ALT_READY_LINE" > "$state_line"
  install_dynamic_crew_state "$fakebin"
  printf 'Working...\n' > "$dir/pane"
  out="$dir/watch.out"
  FM_FAKE_CREW_STATE_FILE="$state_line" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  sleep 2.5
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; fail "volatile ready detail emitted a duplicate wake"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "volatile ready detail printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "volatile ready detail queued a duplicate wake"; }
  reap "$pid"
  pass "watcher deduplicates volatile ready detail for the same branch head"
}

test_done_status_seeds_next_generation_dedupe() {
  local dir state fakebin first_out second_out pid
  dir=$(make_case done-status-dedupe); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" status-ready off
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$state/status-ready.status"
  printf 'Working...\n' > "$dir/pane"
  first_out="$dir/first.out"
  FM_FAKE_CREW_STATE="$STATUS_READY_LINE" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$first_out" &
  pid=$!
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "done/checks-green status did not wake"; }
  grep -F 'signal:' "$first_out" >/dev/null || fail "done/checks-green status did not use the signal path"
  grep -F 'authoritative PR-ready transition' "$first_out" >/dev/null \
    && fail "done/checks-green status emitted a second readiness reason in its generation"
  [ -s "$state/.pr-ready-status-ready" ] \
    || fail "done/checks-green signal did not persist the authoritative readiness marker"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "wake drain failed after done/checks-green signal"

  second_out="$dir/second.out"
  FM_FAKE_CREW_STATE="$ALT_READY_LINE" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$second_out" &
  pid=$!
  sleep 2.5
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; fail "next watcher generation duplicated status-reported readiness"; }
  [ ! -s "$second_out" ] || { reap "$pid"; fail "next generation printed a duplicate wake: $(cat "$second_out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "next generation queued duplicate readiness"; }
  reap "$pid"
  pass "done/checks-green signal suppresses duplicate readiness in the next watcher generation"
}

test_done_status_dedupes_through_transient_identity_failures() {
  local dir state fakebin first_out second_out pid
  dir=$(make_case done-status-transient); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" status-transient off
  printf 'done: PR https://github.com/o/r/pull/7 checks green\n' > "$state/status-transient.status"
  printf 'Working...\n' > "$dir/pane"
  git -C "$dir/status-transient-wt" checkout -q --detach
  first_out="$dir/first.out"
  FM_FAKE_CREW_STATE='' FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$first_out" &
  pid=$!
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "done status did not wake through transient identity failures"; }
  grep -F 'signal:' "$first_out" >/dev/null || fail "done status missed its signal wake"
  [ -e "$state/.pr-ready-status-surfaced-status-transient" ] \
    || fail "done status did not persist fallback dedupe state"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "wake drain failed after transient done status"
  git -C "$dir/status-transient-wt" checkout -q "fm/status-transient"

  second_out="$dir/second.out"
  FM_FAKE_CREW_STATE="$READY_LINE" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$second_out" &
  pid=$!
  sleep 2.5
  kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; fail "recovered identity duplicated status readiness"; }
  [ ! -s "$second_out" ] || { reap "$pid"; fail "recovered identity printed a duplicate wake: $(cat "$second_out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "recovered identity queued duplicate readiness"; }
  [ -s "$state/.pr-ready-status-transient" ] || { reap "$pid"; fail "recovered identity did not replace fallback state"; }
  [ ! -e "$state/.pr-ready-status-surfaced-status-transient" ] \
    || { reap "$pid"; fail "recovered identity left fallback state behind"; }
  reap "$pid"
  pass "done status deduplicates through transient state and git identity failures"
}

test_coarse_status_refines_to_authoritative_baseline() {
  local dir state fakebin first known marker
  dir=$(make_case coarse-status-refinement); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" coarse-status off
  first=$(next_ready "$state" "$fakebin" coarse-status "$COARSE_STATUS_READY_LINE")
  [ -n "$first" ] || fail "coarse status readiness missed its first transition"
  commit_record "$state" "$first"
  known=$(next_ready "$state" "$fakebin" coarse-status "$READY_LINE")
  [ -z "$known" ] || fail "authoritative baseline duplicated coarse status readiness"
  marker=$(cat "$state/.pr-ready-coarse-status")
  case "$marker" in *'run=run-7|detail=baseline') ;; *) fail "authoritative baseline did not refine the coarse marker" ;; esac
  pass "coarse status readiness refines to authoritative baseline without a duplicate"
}

test_identity_refinement_relation_matrix() {
  local row prior current expected actual
  while IFS=$'\t' read -r prior current expected; do
    [ -n "$prior" ] || continue
    actual=$(fm_pr_ready_identity_relation "$prior" "$current")
    [ "$actual" = "$expected" ] \
      || fail "identity relation $prior -> $current was $actual, expected $expected"
  done <<'MATRIX'
fm/task|head-1	fm/task|head-1	same
fm/task|head-1	fm/task|head-1|run=run-7	upgrade
fm/task|head-1	fm/task|head-1|run=run-7|detail=baseline	upgrade
fm/task|head-1	fm/task|head-1|detail=baseline|run=run-7	upgrade
fm/task|head-1|run=run-7	fm/task|head-1|detail=baseline|run=run-7	upgrade
fm/task|head-1|detail=baseline	fm/task|head-1|run=run-7|detail=baseline	upgrade
fm/task|head-1|run=run-7|detail=baseline	fm/task|head-1|detail=baseline|run=run-7	same
fm/task|head-1|run=run-7|detail=baseline	fm/task|head-1|run=run-7	same
fm/task|head-1|run=run-7	fm/task|head-1|run=run-7|detail=relapse-42:1	upgrade
fm/task|head-1|run=run-7|detail=baseline	fm/task|head-1|run=run-7|detail=relapse-42:1	upgrade
fm/task|head-1|run=run-7|detail=baseline	fm/task|head-1|run=run-8|detail=baseline	different
fm/task|head-1|run=run-7|detail=baseline	fm/other|head-1|run=run-7|detail=baseline	different
fm/task|head-1|run=run-7|detail=baseline	fm/task|head-2|run=run-7|detail=baseline	different
MATRIX
  pass "same-head identity refinement is silent while branch and head changes stay distinct"
}

test_changed_run_identity_resurfaces_same_head() {
  local dir state fakebin first rearmed
  dir=$(make_case changed-run-identity); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" changed-run off
  first=$(next_ready "$state" "$fakebin" changed-run "$UNKNOWN_READY_LINE")
  commit_record "$state" "$first"
  rearmed=$(next_ready "$state" "$fakebin" changed-run "$REARMED_READY_LINE")
  [ -n "$rearmed" ] || fail "new authoritative run on the same head was silently refined"
  pass "new authoritative run identity re-surfaces same-head readiness"
}

test_unknown_generation_upgrades_without_duplicate() {
  local dir state fakebin first known recovered marker
  dir=$(make_case unknown-generation); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" unknown-generation off
  first=$(next_ready "$state" "$fakebin" unknown-generation "$UNKNOWN_READY_LINE")
  [ -n "$first" ] || fail "unknown CI generation missed its first ready transition"
  commit_record "$state" "$first"
  known=$(next_ready "$state" "$fakebin" unknown-generation "$READY_LINE")
  [ -z "$known" ] || fail "newly readable CI generation duplicated readiness"
  marker=$(cat "$state/.pr-ready-unknown-generation")
  case "$marker" in *'run=run-7|detail=baseline') ;; *) fail "newly readable CI generation did not upgrade the marker" ;; esac
  recovered=$(next_ready "$state" "$fakebin" unknown-generation "$RECOVERED_READY_LINE")
  [ -z "$recovered" ] || fail "newly readable same-HEAD history duplicated readiness"
  pass "unknown CI generation anchors and refines without duplicate wake"
}

test_hidden_preexisting_relapse_refines_without_duplicate() {
  local dir state fakebin first recovered marker
  dir=$(make_case hidden-preexisting-relapse); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" hidden-relapse off
  first=$(next_ready "$state" "$fakebin" hidden-relapse "$UNKNOWN_READY_LINE")
  [ -n "$first" ] || fail "unreadable initial readiness did not wake"
  commit_record "$state" "$first"
  recovered=$(next_ready "$state" "$fakebin" hidden-relapse "$RECOVERED_READY_LINE")
  [ -z "$recovered" ] || fail "newly readable preexisting relapse duplicated readiness"
  marker=$(cat "$state/.pr-ready-hidden-relapse")
  case "$marker" in *'relapse-1289303112:42') ;; *) fail "newly readable history did not refine the marker" ;; esac
  pass "hidden preexisting relapse refines readiness without a duplicate"
}

test_observed_relapse_survives_watcher_restart() {
  local dir state fakebin first after superseded
  dir=$(make_case observed-relapse-restart); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" observed-relapse off
  first=$(next_ready "$state" "$fakebin" observed-relapse "$UNKNOWN_READY_LINE")
  commit_record "$state" "$first"
  FM_STATE_OVERRIDE="$state" FM_FAKE_CREW_STATE="$WORKING_LINE" \
    FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '. "$1"; fm_pr_ready_transition "$2" observed-relapse >/dev/null || true' \
      _ "$ROOT/bin/fm-pr-ready-lib.sh" "$state"
  [ ! -e "$state/.pr-ready-observed-relapse" ] || fail "observed relapse left the ready marker active"
  superseded="$state/.pr-ready-superseded-observed-relapse"
  [ -s "$superseded" ] || fail "observed relapse did not persist supersession"
  after=$(FM_STATE_OVERRIDE="$state" FM_FAKE_CREW_STATE="$RECOVERED_READY_LINE" \
    FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '. "$1"; fm_pr_ready_transition "$2" observed-relapse || true' \
      _ "$ROOT/bin/fm-pr-ready-lib.sh" "$state")
  [ -n "$after" ] || fail "watcher restart lost observed relapse supersession"
  commit_record "$state" "$after"
  [ ! -e "$superseded" ] || fail "committed recovery did not clear supersession"
  pass "observed relapse persists across watcher restart and re-surfaces green"
}

test_transient_git_identity_failure_preserves_marker() {
  local dir state fakebin first marker before after
  dir=$(make_case git-identity-failure); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" git-failure off
  first=$(next_ready "$state" "$fakebin" git-failure "$READY_LINE")
  commit_record "$state" "$first"
  marker="$state/.pr-ready-git-failure"
  before=$(cat "$marker")
  git -C "$dir/git-failure-wt" checkout -q --detach
  [ -z "$(next_ready "$state" "$fakebin" git-failure "$READY_LINE")" ] \
    || fail "unreadable branch identity emitted a duplicate readiness wake"
  after=$(cat "$marker")
  [ "$after" = "$before" ] || fail "unreadable branch identity changed the readiness marker"
  pass "transient git identity failure preserves prior readiness"
}

test_signal_cannot_starve_pr_ready_sweep() {
  local dir state fakebin out pid
  dir=$(make_case signal-starvation); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" signal-ready off
  printf 'blocked: unrelated decision required\n' > "$state/unrelated.status"
  printf 'Working...\n' > "$dir/pane"
  out="$dir/watch.out"
  FM_FAKE_CREW_STATE="$READY_LINE" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "unrelated signal starved PR-ready scan"; }
  grep -F "check: authoritative PR-ready transition for signal-ready" "$out" >/dev/null \
    || fail "unrelated actionable signal outran the due PR-ready scan"
  pass "actionable signals cannot starve bounded PR-ready scans"
}

test_unobserved_relapse_history_refines_without_duplicate() {
  local dir state fakebin first recovered
  dir=$(make_case unobserved-relapse); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" unobserved-relapse off
  first=$(next_ready "$state" "$fakebin" unobserved-relapse "$READY_LINE")
  commit_record "$state" "$first"
  recovered=$(next_ready "$state" "$fakebin" unobserved-relapse "$RECOVERED_READY_LINE")
  [ -z "$recovered" ] || fail "unobserved same-HEAD history emitted a duplicate"
  pass "unobserved same-HEAD relapse history is benign refinement"
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

test_busy_pane_rearm_is_observed_by_task_scan() {
  local dir state fakebin record marker state_line out pid
  dir=$(make_case busy-pane-rearm); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" busy-rearm off
  record=$(next_ready "$state" "$fakebin" busy-rearm "$READY_LINE")
  commit_record "$state" "$record"
  marker="$state/.pr-ready-busy-rearm"
  state_line="$dir/crew-state"
  printf '%s\n' "$WORKING_LINE" > "$state_line"
  install_dynamic_crew_state "$fakebin"
  printf 'Working...\n' > "$dir/pane"
  out="$dir/watch.out"
  FM_FAKE_CREW_STATE_FILE="$state_line" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_marker_clear "$marker" "$pid" || { reap "$pid"; fail "busy-pane re-arm did not clear prior readiness"; }
  printf '%s\n' "$READY_LINE" > "$state_line"
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "busy-pane green recovery did not wake"; }
  grep -F "check: authoritative PR-ready transition for busy-rearm" "$out" >/dev/null \
    || fail "busy-pane green recovery did not emit a fresh transition"
  pass "bounded task scans observe re-arm and renewed green while the pane is busy"
}

test_changing_pane_failure_is_observed_by_task_scan() {
  local dir state fakebin record marker state_line out pid key old_hash
  dir=$(make_case changing-pane-failure); state="$dir/state"; fakebin="$dir/fakebin"
  make_task "$dir" changing-failure off
  record=$(next_ready "$state" "$fakebin" changing-failure "$READY_LINE")
  commit_record "$state" "$record"
  marker="$state/.pr-ready-changing-failure"
  state_line="$dir/crew-state"
  printf '%s\n' "$FAILED_LINE" > "$state_line"
  install_dynamic_crew_state "$fakebin"
  printf 'new changing pane\n' > "$dir/pane"
  key=$(printf '%s' 'test:fm-changing-failure' | tr ':/.' '___')
  old_hash=$(hash_text 'old pane')
  printf '%s' "$old_hash" > "$state/.hash-$key"
  out="$dir/watch.out"
  FM_FAKE_CREW_STATE_FILE="$state_line" FM_FAKE_TMUX_CAPTURE="$dir/pane" \
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PR_READY_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PR_READY_SCAN_INTERVAL=0 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_marker_clear "$marker" "$pid" || { reap "$pid"; fail "changing-pane failure did not clear prior readiness"; }
  printf '%s\n' "$READY_LINE" > "$state_line"
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "changing-pane green recovery did not wake"; }
  grep -F "check: authoritative PR-ready transition for changing-failure" "$out" >/dev/null \
    || fail "changing-pane green recovery did not emit a fresh transition"
  pass "bounded task scans observe failure and renewed green while the pane changes"
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

test_pr_ready_state_cleanup() {
  local dir state
  dir=$(make_case state-cleanup); state="$dir/state"
  touch "$state/.pr-ready-cleanup" "$state/.last-pr-ready-cleanup" \
    "$state/.pr-ready-superseded-cleanup" "$state/.pr-ready-status-surfaced-cleanup"
  fm_pr_ready_cleanup "$state" cleanup
  [ ! -e "$state/.pr-ready-cleanup" ] || fail "readiness marker survived cleanup"
  [ ! -e "$state/.last-pr-ready-cleanup" ] || fail "readiness cadence marker survived cleanup"
  [ ! -e "$state/.pr-ready-superseded-cleanup" ] || fail "readiness supersession survived cleanup"
  [ ! -e "$state/.pr-ready-status-surfaced-cleanup" ] || fail "status readiness fallback survived cleanup"
  grep -F "fm_pr_ready_cleanup \"\$STATE\" \"\$ID\"" "$ROOT/bin/fm-teardown.sh" >/dev/null \
    || fail "normal teardown does not invoke PR-ready cleanup"
  grep -F "fm_pr_ready_cleanup \"\$sub_state\" \"\$child_id\"" "$ROOT/bin/fm-teardown.sh" >/dev/null \
    || fail "secondmate-child teardown does not invoke PR-ready cleanup"
  pass "normal and secondmate-child teardown remove persistent PR-ready state"
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
test_volatile_ready_detail_does_not_wake_again
test_done_status_seeds_next_generation_dedupe
test_done_status_dedupes_through_transient_identity_failures
test_coarse_status_refines_to_authoritative_baseline
test_identity_refinement_relation_matrix
test_changed_run_identity_resurfaces_same_head
test_unknown_generation_upgrades_without_duplicate
test_hidden_preexisting_relapse_refines_without_duplicate
test_observed_relapse_survives_watcher_restart
test_transient_git_identity_failure_preserves_marker
test_signal_cannot_starve_pr_ready_sweep
test_unobserved_relapse_history_refines_without_duplicate
test_relapse_rearm_and_head_change_supersede_green
test_busy_pane_rearm_is_observed_by_task_scan
test_changing_pane_failure_is_observed_by_task_scan
test_approval_posture_changes_reason_not_authority
test_pr_ready_state_cleanup
test_keyed_pause_precedence_and_stale_absorption
printf 'all fm-pr-ready wake tests passed\n'
