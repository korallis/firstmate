#!/usr/bin/env bash
# Behavior tests for the firstmate MCP server (mcp/).
#
# Runs TypeScript unit tests with mocked bin/fm-* calls, then a local MCP
# handshake smoke that lists all five tools and calls read-only handlers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MCP_DIR="$ROOT/mcp"

test_package_builds_and_unit_tests_pass() {
  if ! command -v npm >/dev/null 2>&1; then
    fail "npm is required for mcp tests"
  fi
  ( cd "$MCP_DIR" && npm install --silent && npm test ) || fail "mcp unit tests failed"
  pass "mcp: unit tests pass"
}

test_smoke_lists_tools_and_reads_fleet() {
  local fm_home=${FM_HOME:-$ROOT}
  FM_HOME="$fm_home" npm --prefix "$MCP_DIR" run smoke --silent \
    || fail "mcp smoke handshake failed"
  pass "mcp: smoke lists tools and fleet_status reads live backlog"
}

test_steer_is_only_mutating_tool_in_manifest() {
  assert_grep '"steer_task"' "$MCP_DIR/src/tools.ts" "steer_task tool missing from registration"
  assert_grep 'ONLY mutating tool' "$MCP_DIR/src/tools.ts" "steer_task missing mutating marker in description"
  pass "mcp: steer_task documented as sole writer"
}

test_package_builds_and_unit_tests_pass
test_smoke_lists_tools_and_reads_fleet
test_steer_is_only_mutating_tool_in_manifest
