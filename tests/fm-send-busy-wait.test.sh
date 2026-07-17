#!/usr/bin/env bash
# fm-send busy-agent wait: do not type text while the target reports busy, so
# steers are not merely queued behind a long shell (Pi "Steering:" trap).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-busy-wait)
mkdir -p "$TMP_ROOT"

# Exercise the SHIPPED fm_send_wait_until_idle (bin/fm-send-wait-lib.sh), not a
# copy: source the real helper and drive it with a stubbed fm_backend_busy_state.
# A harness subshell runs the real function so a failing (return 1) budget path
# does not abort this test under set -e.
cat >"$TMP_ROOT/wait-harness.sh" <<H
#!/usr/bin/env bash
set -u
# Simulate fm_backend_busy_state: first N polls busy, then idle.
COUNT_FILE=\${COUNT_FILE:?}
N_BUSY=\${N_BUSY:-2}
RESOLUTION_TRIED="meta=stub; backend=herdr"
fm_backend_busy_state() {
  local n
  n=\$(cat "\$COUNT_FILE")
  n=\$((n + 1))
  printf '%s' "\$n" >"\$COUNT_FILE"
  if [ "\$n" -le "\$N_BUSY" ]; then
    printf 'busy'
  else
    printf 'idle'
  fi
}
. "$ROOT/bin/fm-send-wait-lib.sh"
if fm_send_wait_until_idle herdr pane; then
  printf 'rc=0\n'
else
  printf 'rc=1\n'
fi
H
chmod +x "$TMP_ROOT/wait-harness.sh"

# Busy for 2 polls of 1s, then idle: succeeds and delivers.
export COUNT_FILE="$TMP_ROOT/count"
export N_BUSY=2
export FM_SEND_BUSY_WAIT_SECS=30
export FM_SEND_BUSY_POLL_SECS=1
printf '0' >"$COUNT_FILE"
out=$(bash "$TMP_ROOT/wait-harness.sh" 2>"$TMP_ROOT/err")
assert_contains "$out" 'rc=0' "expected success after 2 busy polls, got: $out / $(cat "$TMP_ROOT/err")"
assert_grep 'idle after' "$TMP_ROOT/err" "expected idle-after progress line on stderr"
[ "$(cat "$COUNT_FILE")" = 3 ] || fail "expected 3 busy_state polls (2 busy + 1 idle), got $(cat "$COUNT_FILE")"
pass "busy-wait polls until idle then delivers"

# Fail loudly after the wait budget: agent stays busy forever, wait budget is
# short, the shipped helper must return non-zero and print the error. This is the
# path the intent requires ("fail loudly after wait budget") and the one a copied
# loop previously never exercised.
export N_BUSY=100
export FM_SEND_BUSY_WAIT_SECS=2
export FM_SEND_BUSY_POLL_SECS=1
printf '0' >"$COUNT_FILE"
out=$(bash "$TMP_ROOT/wait-harness.sh" 2>"$TMP_ROOT/err")
assert_contains "$out" 'rc=1' "expected failure when agent never idles within budget, got: $out"
assert_grep 'still busy after 2s' "$TMP_ROOT/err" "expected loud budget-exhaustion error on stderr"
assert_grep 'backend=herdr' "$TMP_ROOT/err" "expected RESOLUTION_TRIED echoed in budget-exhaustion error"
pass "busy-wait fails loudly after wait budget"

# Disabled wait returns immediately even if busy forever, without polling.
export FM_SEND_BUSY_WAIT_SECS=0
export N_BUSY=100
printf '0' >"$COUNT_FILE"
out=$(bash "$TMP_ROOT/wait-harness.sh" 2>"$TMP_ROOT/err")
assert_contains "$out" 'rc=0' "disabled wait should return 0, got: $out"
[ "$(cat "$COUNT_FILE")" = 0 ] || fail "disabled wait must not poll busy_state, count=$(cat "$COUNT_FILE")"
pass "busy-wait disabled with FM_SEND_BUSY_WAIT_SECS=0"

# Confirm fm-send.sh still wires the wait on the text path (and only there).
grep -q 'fm_send_wait_until_idle "\$TARGET_BACKEND" "\$T"' "$SEND" || fail "fm-send.sh missing busy-wait call on text path"
pass "fm-send.sh wires busy-wait on text path"
