#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)
EMPTY_CONFIG="$TMP_ROOT/config"
mkdir -p "$EMPTY_CONFIG"

test_cursor_agent_marker() {
  local got
  got=$(CURSOR_AGENT=1 "$HARNESS")
  [ "$got" = cursor ] || fail "CURSOR_AGENT should detect cursor, got '$got'"
  pass "CURSOR_AGENT detects cursor harness"
}

test_cursor_extension_host_role_marker() {
  local got
  got=$(CURSOR_EXTENSION_HOST_ROLE=agent-exec "$HARNESS")
  [ "$got" = cursor ] || fail "CURSOR_EXTENSION_HOST_ROLE=agent-exec should detect cursor, got '$got'"
  pass "CURSOR_EXTENSION_HOST_ROLE=agent-exec detects cursor harness"
}

test_cursor_wins_over_claude_marker() {
  local got
  got=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$got" = cursor ] || fail "cursor should win when CURSOR_AGENT and CLAUDECODE are both set, got '$got'"
  pass "cursor marker wins over CLAUDECODE when both are set"
}

test_cursor_not_dispatchable_for_crew() {
  local got
  got=$(FM_CONFIG_OVERRIDE="$EMPTY_CONFIG" CURSOR_AGENT=1 "$HARNESS" crew)
  [ "$got" = unknown ] || fail "crew must not resolve cursor until verified, got '$got'"
  pass "cursor is excluded from crew harness resolution"
}

test_cursor_not_dispatchable_for_secondmate() {
  local got
  got=$(FM_CONFIG_OVERRIDE="$EMPTY_CONFIG" CURSOR_AGENT=1 "$HARNESS" secondmate)
  [ "$got" = unknown ] || fail "secondmate must not resolve cursor until verified, got '$got'"
  pass "cursor is excluded from secondmate harness resolution"
}

test_plugin_manifest_paths_exist() {
  local manifest skills
  manifest="$ROOT/.cursor-plugin/plugin.json"
  assert_present "$manifest" "plugin manifest is missing"
  skills=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["skills"])' "$manifest")
  assert_present "$ROOT/$skills" "plugin skills path does not exist: $skills"
  pass "plugin.json component paths exist on disk"
}

test_fm_lock_acquires_with_cursor_env() {
  local home out
  home="$TMP_ROOT/lock-home-cursor"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" CURSOR_AGENT=1 "$ROOT/bin/fm-lock.sh" 2>&1)
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not acquire under CURSOR_AGENT"
  pass "fm-lock acquires session lock when CURSOR_AGENT is set"
}

test_fm_lock_recognizes_cursor_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home-cursor-holder"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-cursor-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'Cursor'; exit 0 ;;
  *"args="*) printf '%s\n' 'Cursor Helper (Plugin) agent-exec'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize cursor as a live holder"
  pass "fm-lock recognizes cursor harness processes"
}

test_cursor_agent_marker
test_cursor_extension_host_role_marker
test_cursor_wins_over_claude_marker
test_cursor_not_dispatchable_for_crew
test_cursor_not_dispatchable_for_secondmate
test_plugin_manifest_paths_exist
test_fm_lock_acquires_with_cursor_env
test_fm_lock_recognizes_cursor_holder
