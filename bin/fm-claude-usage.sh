#!/usr/bin/env bash
# fm-claude-usage.sh - report the Claude subscription plan's rate-limit state and
# a routing verdict for the in-plan-vs-overage dispatch split.
#
# It reads the Claude Code OAuth access token, calls Anthropic's usage endpoint,
# and reports whether the account is still inside its weekly plan window
# (in-plan) or has reached the threshold where new usage spills into paid extra
# usage (overage). Firstmate consults the verdict before dispatching an
# Opus/Fable-tier task: in-plan routes that tier to Claude Code (plan-covered),
# overage routes it to the Cursor-gateway fallback. The concrete per-tier
# harness/model strings live in config/crew-dispatch.json, not here.
#
# The verdict is driven by the 7-day (weekly, all-models) window utilization,
# which is where usage crosses into extra usage. The threshold is configurable:
#   config/claude-plan-budget (a single integer percent), or
#   FM_CLAUDE_WEEKLY_OVERAGE_PCT (env), default 95.
#
# Usage:
#   fm-claude-usage.sh            one machine-readable line (default), exit-coded
#   fm-claude-usage.sh --verdict  print only: in-plan | overage | unknown
#   fm-claude-usage.sh --human    a readable summary with the window numbers
#   fm-claude-usage.sh --json     the raw usage JSON from the endpoint
#   fm-claude-usage.sh --refresh  bypass the response cache for this call
#
# Exit codes: 0 verdict in-plan, 10 verdict overage, 3 unknown (could not
# determine - no credentials, endpoint error, or unparseable response). A caller
# that only needs a safe boolean should treat any non-zero (overage OR unknown)
# as "do not spend Claude overage - use the fallback".
#
# Token source, in order: $CLAUDE_CONFIG_DIR/.credentials.json (or
# ~/.claude/.credentials.json) for a file-based install, else the macOS Keychain
# generic password under service "Claude Code-credentials". The token is the
# .claudeAiOauth.accessToken field. Claude Code keeps that token fresh; this
# script never writes or refreshes credentials.
#
# Endpoint: GET https://api.anthropic.com/api/oauth/usage with the OAuth bearer
# token and header "anthropic-beta: oauth-2025-04-20". See docs/claude-usage.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

USAGE_URL="${FM_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
BETA_HEADER="anthropic-beta: oauth-2025-04-20"
CACHE="$STATE/.claude-usage-cache.json"
TTL="${FM_CLAUDE_USAGE_TTL:-60}"

die_unknown() {
  # Print the machine line (or bare verdict) for an indeterminate result and exit 3.
  case "$MODE" in
    verdict) printf 'unknown\n' ;;
    json) printf '%s\n' "${1:-{\}}" ;;
    human) printf 'Claude plan usage: UNKNOWN (%s)\n' "${2:-no detail}" ;;
    *) printf 'state=unknown weekly= extra= reason=%s\n' "${2:-unknown}" ;;
  esac
  exit 3
}

# --- credentials ------------------------------------------------------------

creds_json() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  if [ -r "$f" ]; then
    cat "$f"
    return 0
  fi
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null && return 0
  fi
  return 1
}

# --- threshold --------------------------------------------------------------

resolve_threshold() {
  local t="${FM_CLAUDE_WEEKLY_OVERAGE_PCT:-}"
  if [ -z "$t" ] && [ -r "$CONFIG/claude-plan-budget" ]; then
    t="$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG/claude-plan-budget" 2>/dev/null | head -1 | tr -d '[:space:]')"
  fi
  [ -z "$t" ] && t=95
  # Guard against a non-numeric config value.
  case "$t" in
    '' | *[!0-9.]*) t=95 ;;
  esac
  printf '%s' "$t"
}

# --- fetch (with short-TTL cache) -------------------------------------------

cache_fresh() {
  [ -s "$CACHE" ] || return 1
  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)"
  age=$((now - mtime))
  [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ]
}

fetch_usage() {
  # Echo the usage JSON body on success; return non-zero with a reason on stderr.
  if [ "$REFRESH" -eq 0 ] && cache_fresh; then
    cat "$CACHE"
    return 0
  fi
  local token body http tmp
  token="$(creds_json | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$token" ]; then
    echo "no-credentials" >&2
    return 1
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/fm-claude-usage.XXXXXX")" || {
    echo "mktemp-failed" >&2
    return 1
  }
  http="$(curl -sS --max-time 15 -o "$tmp" -w '%{http_code}' "$USAGE_URL" \
    -H "Authorization: Bearer $token" -H "$BETA_HEADER" 2>/dev/null)" || {
    rm -f "$tmp"
    echo "curl-failed" >&2
    return 1
  }
  if [ "$http" != "200" ]; then
    rm -f "$tmp"
    echo "api-$http" >&2
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "bad-json" >&2
    return 1
  fi
  mkdir -p "$STATE" 2>/dev/null || true
  if mv "$tmp" "$CACHE" 2>/dev/null; then
    cat "$CACHE"
  else
    cat "$tmp"
    rm -f "$tmp"
  fi
  return 0
}

# --- main -------------------------------------------------------------------

MODE=line
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --verdict) MODE=verdict ;;
    --human) MODE=human ;;
    --json) MODE=json ;;
    --refresh) REFRESH=1 ;;
    -h | --help)
      sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "fm-claude-usage.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || die_unknown '{}' "jq-not-installed"
command -v curl >/dev/null 2>&1 || die_unknown '{}' "curl-not-installed"

reason=""
if ! body="$(fetch_usage 2>/tmp/fm-claude-usage-reason.$$)"; then
  reason="$(cat /tmp/fm-claude-usage-reason.$$ 2>/dev/null)"
  rm -f /tmp/fm-claude-usage-reason.$$
  die_unknown '{}' "${reason:-fetch-failed}"
fi
rm -f /tmp/fm-claude-usage-reason.$$

if [ "$MODE" = json ]; then
  printf '%s\n' "$body"
  exit 0
fi

# Weekly-all utilization: prefer the self-describing limits[] entry, fall back to
# the flat seven_day field for older response shapes.
weekly="$(printf '%s' "$body" | jq -r '
  ((.limits // []) | map(select(.kind == "weekly_all")) | .[0].percent)
  // .seven_day.utilization // empty' 2>/dev/null)"

if [ -z "$weekly" ] || [ "$weekly" = null ]; then
  die_unknown "$body" "no-weekly-window"
fi

extra_used="$(printf '%s' "$body" | jq -r '.extra_usage.used_credits // 0' 2>/dev/null)"
extra_limit="$(printf '%s' "$body" | jq -r '.extra_usage.monthly_limit // 0' 2>/dev/null)"

threshold="$(resolve_threshold)"

# Float-safe comparison: overage when weekly >= threshold.
verdict="$(awk -v w="$weekly" -v t="$threshold" 'BEGIN { print (w + 0 >= t + 0) ? "overage" : "in-plan" }')"

case "$MODE" in
  verdict)
    printf '%s\n' "$verdict"
    ;;
  human)
    printf 'Claude plan usage: %s\n' "$verdict"
    printf '  weekly (7d, all models): %s%% (overage threshold %s%%)\n' "$weekly" "$threshold"
    printf '  extra usage: %s / %s\n' "$extra_used" "$extra_limit"
    ;;
  *)
    printf 'state=%s weekly=%s threshold=%s extra=%s/%s\n' \
      "$verdict" "$weekly" "$threshold" "$extra_used" "$extra_limit"
    ;;
esac

[ "$verdict" = overage ] && exit 10
exit 0
