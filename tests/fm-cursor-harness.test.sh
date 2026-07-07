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

test_cursor_agent_marker
test_cursor_extension_host_role_marker
test_cursor_wins_over_claude_marker
test_cursor_not_dispatchable_for_crew
test_cursor_not_dispatchable_for_secondmate
test_plugin_manifest_paths_exist
