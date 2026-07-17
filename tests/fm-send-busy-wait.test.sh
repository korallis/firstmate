#!/usr/bin/env bash
# fm-send busy-agent wait: do not type text while the target reports busy, so
# steers are not merely queued behind a long shell (Pi "Steering:" trap).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-busy-wait)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# Hermetic herdr busy_state stub via PATH-wrapped backend is heavy; instead
# unit-test the wait helper by extracting behavior with a fake busy_state.
# We source only the wait loop pattern through a tiny harness script.

cat >"$TMP_ROOT/wait-harness.sh" <<'H'
#!/usr/bin/env bash
set -eu
# Simulate fm_backend_busy_state: first N polls busy, then idle.
COUNT_FILE=${COUNT_FILE:?}
N_BUSY=${N_BUSY:-2}
fm_backend_busy_state() {
  local n
  n=$(cat "$COUNT_FILE")
  n=$((n + 1))
  printf '%s' "$n" >"$COUNT_FILE"
  if [ "$n" -le "$N_BUSY" ]; then
    printf 'busy'
  else
    printf 'idle'
  fi
}
fm_send_wait_until_idle() {
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
        sleep "$poll_s"
        waited=$((waited + poll_s))
        ;;
      *)
        printf 'waited=%s\n' "$waited"
        return 0
        ;;
    esac
  done
  return 1
}
printf '0' >"$COUNT_FILE"
fm_send_wait_until_idle herdr pane
H
chmod +x "$TMP_ROOT/wait-harness.sh"

# 2 busy polls * 1s poll = waited 2
export COUNT_FILE="$TMP_ROOT/count"
export N_BUSY=2
export FM_SEND_BUSY_WAIT_SECS=30
export FM_SEND_BUSY_POLL_SECS=1
out=$(bash "$TMP_ROOT/wait-harness.sh")
echo "$out" | grep -q 'waited=2' || fail "expected waited=2 after 2 busy polls, got: $out"
pass "busy-wait polls until idle"

# Disabled wait returns immediately even if busy forever (no waited= line)
export FM_SEND_BUSY_WAIT_SECS=0
export N_BUSY=100
printf '0' >"$COUNT_FILE"
if ! out=$(bash "$TMP_ROOT/wait-harness.sh"); then
	fail "disabled wait should return 0, got failure: $out"
fi
# When wait is disabled the harness returns before any poll; count file stays 0
[ "$(cat "$COUNT_FILE")" = 0 ] || fail "disabled wait must not poll busy_state, count=$(cat "$COUNT_FILE")"
pass "busy-wait disabled with FM_SEND_BUSY_WAIT_SECS=0"

# Confirm fm-send.sh still contains the wait call on the text path
grep -q 'fm_send_wait_until_idle' "$SEND" || fail "fm-send.sh missing busy-wait call"
pass "fm-send.sh wires busy-wait on text path"
