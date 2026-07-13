Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi`, after approving project trust once per clone); if not, restart with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Arm supervision with the `fm_watch_arm_pi` tool.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and sends a follow-up user message when the child exits with an actionable watcher reason.
5. If the extension says the watcher is already healthy, do not start another cycle.
6. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart Pi with both extensions loaded if needed.
7. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.

Verification on 2026-07-09 used Pi 0.80.5, an isolated `PI_CODING_AGENT_DIR`, an isolated `FM_HOME`, and the dedicated tmux socket `fm-pi-q6-lab`.
The command `Use the fm_watch_arm_pi custom tool now. Do not use bash.` rendered `watcher: started Pi extension arm child 1`, then the model returned `DONE` without the prior `result.content.filter(...)` crash.
The extension tool returned Pi's required text `content` plus structured `details` and used `Type.Object({})` for its parameter schema.
The human command `/fm-watch-arm-pi` notified through `ctx.ui.notify(...)` and returned no value.
The clean-exit probe ran `/quit`, printed `PI_EXIT=0`, and confirmed that both the attached arm process and watcher child were gone.
That cleanup is owned by a one-shot process `exit` listener because Pi 0.80.5 did not reliably emit `session_shutdown` for `/quit`; the listener is removed when `session_shutdown` does run.
Command run for the complete interactive regression: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.5 live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit`.
Command run for the installed-type contract: `tests/fm-pi-primary-types.test.sh`.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.5`.

Reload and Workflow Suite verification on 2026-07-13 used Pi 0.80.6 with `@mediadatafusion/pi-workflow-suite` 0.0.25, an isolated `PI_CODING_AGENT_DIR`, an isolated `FM_HOME`, and a private tmux socket.
Command run for the complete interactive regression: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed output: `ok - Pi 0.80.6 with Workflow Suite 0.0.25 kept the watcher tool active after /reload, guarded once, woke, re-armed, and cleaned up on exit`.
The test loaded the watcher extension before Workflow Suite, ran `/reload`, and proved the first post-reload model turn could call `fm_watch_arm_pi` without widening Workflow Suite's selected tool allowlist.
Command run for deterministic lifecycle and restart coverage: `tests/fm-pi-watch-extension.test.sh`.
Observed output included `ok - Pi watcher tool survives a late reload active-tool reset without widening the mode surface`, `ok - Pi suppresses restart exit 143 only after a fresh home-scoped replacement is verified`, and `ok - Pi keeps restart exit 143 actionable when no fresh home-scoped replacement exists`.
The lifecycle fixture invalidated the captured extension API after resource discovery and would have thrown `extension ctx is stale` from any delayed `getActiveTools` or `setActiveTools` callback, proving the restoration does not rely on a post-handler timer.
The restart fixture reproduced `watcher: FAILED - fm-watch-arm.sh exited 143` from the replaced arm and `watcher: started pid=222 (beacon fresh)` from its successor; exit 143 was suppressed only when the canonical home-scoped watcher-health predicate confirmed a different live watcher with a fresh beacon.
Command run for the installed-type contract: `PATH="$HOME/.npm/_npx/9ca470fa61f45e06/node_modules/.bin:$PATH" tests/fm-pi-primary-types.test.sh`.
Observed output: `ok - Pi primary extensions pass strict no-emit typecheck against Pi 0.80.6`.
