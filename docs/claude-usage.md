# Claude plan usage reporting (`bin/fm-claude-usage.sh`)

`bin/fm-claude-usage.sh` reports whether the Claude subscription plan is still inside its weekly window (in-plan) or has reached the point where new usage spills into paid extra usage (overage).
It exists so a fleet that routes an Opus/Fable-tier task to Claude Code while in-plan can fall back to a paid gateway (for example the Cursor gateway) once the plan window is exhausted, instead of silently spending Claude overage.
The routing policy that consumes the verdict is per-fleet and lives in local config (for this fleet, `config/crew-dispatch.json`); this tool only reports state.

## Data source

Claude Code does not persist the `/usage` window percentages to any local file.
That data comes from Anthropic's OAuth usage endpoint, which returns the same numbers the `/usage` screen shows, including a dedicated extra-usage (overage) field.

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth-access-token>
anthropic-beta: oauth-2025-04-20
```

The OAuth access token is the `.claudeAiOauth.accessToken` field of the Claude Code credentials.
On a file-based install the credentials live at `$CLAUDE_CONFIG_DIR/.credentials.json` (default `~/.claude/.credentials.json`).
On macOS they live in the login Keychain as a generic password under service `Claude Code-credentials`; the script reads it with `security find-generic-password -s "Claude Code-credentials" -w`.
Claude Code keeps that token fresh (it refreshes roughly hourly while running); the script only reads the token and never writes or refreshes credentials.

## Response shape

The fields the tool reads:

- `limits[]` - a self-describing array; the entry with `kind == "weekly_all"` carries the 7-day all-models window `percent` and `severity`.
- `seven_day.utilization` - the flat 7-day utilization, used as a fallback when `limits[]` is absent.
- `extra_usage` - `is_enabled`, `used_credits`, `monthly_limit`, and `utilization` for the overage budget (surfaced in output; not part of the verdict by default).

## Verdict

The verdict is driven by the 7-day (weekly, all-models) window utilization, because that is the window whose exhaustion pushes usage into extra usage.

- `in-plan` - weekly utilization is below the overage threshold.
- `overage` - weekly utilization is at or above the threshold.
- `unknown` - the state could not be determined (no credentials, endpoint error, or an unparseable response).

The threshold is the percentage at which the tool declares overage, so a fleet can glide off the plan just before it starts costing extra.
It resolves from `FM_CLAUDE_WEEKLY_OVERAGE_PCT` (env), then `config/claude-plan-budget` (a single integer percent), then the default `95`.

A caller that only needs a safe boolean should treat any non-zero exit (overage or unknown) as "do not spend Claude overage - use the fallback".

## Output modes and exit codes

| Invocation | Output | Exit |
| --- | --- | --- |
| `fm-claude-usage.sh` | `state=<verdict> weekly=<pct> threshold=<pct> extra=<used>/<limit>` | 0 in-plan, 10 overage, 3 unknown |
| `fm-claude-usage.sh --verdict` | `in-plan` / `overage` / `unknown` | same |
| `fm-claude-usage.sh --human` | readable summary with the window numbers | same |
| `fm-claude-usage.sh --json` | the raw usage JSON from the endpoint | 0, or 3 on failure |
| `fm-claude-usage.sh --refresh` | as default, bypassing the response cache | same |

Responses are cached under `state/.claude-usage-cache.json` for `FM_CLAUDE_USAGE_TTL` seconds (default 60) so repeated dispatch-time checks do not hammer the endpoint.
`--refresh` forces a fresh call.

## Verification

Verified 2026-07-07 against the live endpoint on macOS (token read from the login Keychain), Claude Max 20x plan.

Live call returned the expected shape and the tool reported overage while the weekly window was full:

```
$ bin/fm-claude-usage.sh --human
Claude plan usage: overage
  weekly (7d, all models): 100% (overage threshold 95%)
  extra usage: 90369.0 / 100000
```

The hermetic suite (`tests/fm-claude-usage.test.sh`) fakes `curl`, `security`, and the credentials file to cover in-plan, overage, config and env thresholds, missing credentials, endpoint error, the `seven_day` fallback shape, response caching plus `--refresh`, and the `--verdict`/`--json` modes.

```
$ bash tests/fm-claude-usage.test.sh
ok - A in-plan below threshold -> state=in-plan exit 0
ok - B weekly at 100% -> state=overage exit 10
ok - C config/claude-plan-budget threshold honored
ok - D FM_CLAUDE_WEEKLY_OVERAGE_PCT overrides config file
ok - E missing credentials -> state=unknown exit 3
ok - F non-200 endpoint -> state=unknown exit 3
ok - G seven_day fallback used when limits[] absent
ok - H response cached within TTL; --refresh bypasses it
ok - I --verdict and --json modes
# all fm-claude-usage tests passed
```
