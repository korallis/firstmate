#!/usr/bin/env bash
# tests/fm-claude-usage.test.sh - hermetic tests for fm-claude-usage.sh, the
# Claude plan usage/overage reporter that drives the in-plan-vs-overage dispatch
# split.
#
# Everything external is faked: `curl` is shimmed to return a canned usage JSON
# body and a chosen HTTP code (no network), `security` is shimmed to fail (no
# Keychain), and credentials come from a temp CLAUDE_CONFIG_DIR/.credentials.json
# so the file path is exercised. jq/awk/date/stat are the real tools. The cache
# and threshold config live under per-case FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE
# dirs, so nothing touches the live home.
#
# Coverage:
#   A) weekly below threshold -> state=in-plan, exit 0
#   B) weekly at/above threshold -> state=overage, exit 10
#   C) threshold from config/claude-plan-budget is honored
#   D) FM_CLAUDE_WEEKLY_OVERAGE_PCT overrides the config file
#   E) missing credentials -> state=unknown, exit 3
#   F) non-200 endpoint -> state=unknown, exit 3
#   G) limits[] weekly_all is preferred; seven_day is the fallback shape
#   H) response cache: a second call within TTL does not re-invoke curl;
#      --refresh forces a re-fetch
#   I) --verdict and --json output modes
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-claude-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-usage)

# Build a per-case sandbox: a fakebin with curl+security shims, a credentials
# dir, and empty state/config override dirs. Echoes the case dir.
make_case() {
  local name=$1 body=$2 http=${3:-200} creds=${4:-yes}
  local dir="$TMP_ROOT/$name"
  local fakebin="$dir/fakebin"
  mkdir -p "$fakebin" "$dir/state" "$dir/config" "$dir/cfgdir"
  printf '%s' "$body" >"$dir/body.json"

  cat >"$fakebin/curl" <<EOF
#!/usr/bin/env bash
[ -n "\${FAKE_CURL_COUNT:-}" ] && printf 'x' >>"\$FAKE_CURL_COUNT"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cp "$dir/body.json" "\$out"
printf '%s' "$http"
EOF
  chmod +x "$fakebin/curl"

  # security shim: always fail, so the Keychain path yields nothing.
  cat >"$fakebin/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$fakebin/security"

  if [ "$creds" = yes ]; then
    printf '%s' '{"claudeAiOauth":{"accessToken":"sk-fake-token"}}' >"$dir/cfgdir/.credentials.json"
  fi
  printf '%s\n' "$dir"
}

# Run the script in a case sandbox. Extra env assignments come as KEY=VAL args
# after the mode flag.
run_case() {
  local dir=$1 flag=$2
  shift 2
  env -i \
    PATH="$dir/fakebin:$PATH" \
    HOME="$dir" \
    CLAUDE_CONFIG_DIR="$dir/cfgdir" \
    FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    "$@" \
    bash "$SCRIPT" ${flag:+"$flag"}
}

OVERAGE_BODY='{"seven_day":{"utilization":100.0},"limits":[{"kind":"weekly_all","percent":100}],"extra_usage":{"used_credits":90000,"monthly_limit":100000}}'
INPLAN_BODY='{"seven_day":{"utilization":40.0},"limits":[{"kind":"weekly_all","percent":40}],"extra_usage":{"used_credits":0,"monthly_limit":100000}}'
FALLBACK_BODY='{"seven_day":{"utilization":42.0},"extra_usage":{"used_credits":0,"monthly_limit":100000}}'

# A) in-plan
test_inplan() {
  local dir out rc
  dir=$(make_case inplan "$INPLAN_BODY")
  out=$(run_case "$dir" "") ; rc=$?
  case "$out" in *"state=in-plan"*) : ;; *) fail "A in-plan: unexpected line: $out" ;; esac
  [ "$rc" -eq 0 ] || fail "A in-plan: expected exit 0, got $rc"
  pass "A in-plan below threshold -> state=in-plan exit 0"
}

# B) overage
test_overage() {
  local dir out rc
  dir=$(make_case overage "$OVERAGE_BODY")
  out=$(run_case "$dir" "") ; rc=$?
  case "$out" in *"state=overage"*) : ;; *) fail "B overage: unexpected line: $out" ;; esac
  [ "$rc" -eq 10 ] || fail "B overage: expected exit 10, got $rc"
  pass "B weekly at 100% -> state=overage exit 10"
}

# C) threshold from config file (set 30 -> weekly 40 becomes overage)
test_config_threshold() {
  local dir out
  dir=$(make_case cfgthresh "$INPLAN_BODY")
  printf '30\n' >"$dir/config/claude-plan-budget"
  out=$(run_case "$dir" "")
  case "$out" in *"state=overage"*"threshold=30"*) : ;; *) fail "C config threshold: $out" ;; esac
  pass "C config/claude-plan-budget threshold honored"
}

# D) env overrides config
test_env_overrides_config() {
  local dir out
  dir=$(make_case envthresh "$INPLAN_BODY")
  printf '30\n' >"$dir/config/claude-plan-budget"
  out=$(run_case "$dir" "" FM_CLAUDE_WEEKLY_OVERAGE_PCT=50)
  case "$out" in *"state=in-plan"*"threshold=50"*) : ;; *) fail "D env override: $out" ;; esac
  pass "D FM_CLAUDE_WEEKLY_OVERAGE_PCT overrides config file"
}

# E) no credentials -> unknown
test_no_creds() {
  local dir out rc
  dir=$(make_case nocreds "$INPLAN_BODY" 200 no)
  out=$(run_case "$dir" "") ; rc=$?
  case "$out" in *"state=unknown"*"no-credentials"*) : ;; *) fail "E no-creds line: $out" ;; esac
  [ "$rc" -eq 3 ] || fail "E no-creds: expected exit 3, got $rc"
  pass "E missing credentials -> state=unknown exit 3"
}

# F) endpoint error -> unknown
test_api_error() {
  local dir out rc
  dir=$(make_case apierr "$INPLAN_BODY" 401)
  out=$(run_case "$dir" "") ; rc=$?
  case "$out" in *"state=unknown"*"api-401"*) : ;; *) fail "F api-error line: $out" ;; esac
  [ "$rc" -eq 3 ] || fail "F api-error: expected exit 3, got $rc"
  pass "F non-200 endpoint -> state=unknown exit 3"
}

# G) fallback to seven_day when limits[] absent
test_fallback_shape() {
  local dir out
  dir=$(make_case fallback "$FALLBACK_BODY")
  out=$(run_case "$dir" "" FM_CLAUDE_WEEKLY_OVERAGE_PCT=95)
  case "$out" in *"state=in-plan"*"weekly=42"*) : ;; *) fail "G fallback shape: $out" ;; esac
  pass "G seven_day fallback used when limits[] absent"
}

# H) cache: 2 calls -> 1 curl; --refresh forces a second
test_cache() {
  local dir n
  dir=$(make_case cache "$INPLAN_BODY")
  local counter="$dir/curlcount"
  run_case "$dir" "" FAKE_CURL_COUNT="$counter" FM_CLAUDE_USAGE_TTL=300 >/dev/null
  run_case "$dir" "" FAKE_CURL_COUNT="$counter" FM_CLAUDE_USAGE_TTL=300 >/dev/null
  n=$(wc -c <"$counter" | tr -d ' ')
  [ "$n" -eq 1 ] || fail "H cache: expected 1 curl call, got $n"
  run_case "$dir" --refresh FAKE_CURL_COUNT="$counter" FM_CLAUDE_USAGE_TTL=300 >/dev/null
  n=$(wc -c <"$counter" | tr -d ' ')
  [ "$n" -eq 2 ] || fail "H cache: --refresh should re-fetch, count=$n"
  pass "H response cached within TTL; --refresh bypasses it"
}

# I) output modes
test_output_modes() {
  local dir out
  dir=$(make_case modes "$OVERAGE_BODY")
  out=$(run_case "$dir" --verdict)
  [ "$out" = overage ] || fail "I --verdict: got '$out'"
  out=$(run_case "$dir" --json)
  case "$out" in *'"weekly_all"'*'"extra_usage"'*) : ;; *) fail "I --json passthrough: $out" ;; esac
  pass "I --verdict and --json modes"
}

test_inplan
test_overage
test_config_threshold
test_env_overrides_config
test_no_creds
test_api_error
test_fallback_shape
test_cache
test_output_modes

echo "# all fm-claude-usage tests passed"
