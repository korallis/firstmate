# firstmate Cursor plugin (C0)

Installing this plugin from Cursor's Customize page wires firstmate's existing assets into your editor without copying them.

## What you get

- **Skills** from `.agents/skills` (afk, bearings, harness adapters, secondmate provisioning, and the rest of firstmate's internal skill library).

The plugin manifest only references paths that already live in the firstmate repo.
It does not duplicate skill or rule content.
Cursor-format hooks are deferred to a later track; Claude Code hooks remain in `.claude/settings.json` for non-plugin installs.

## Running firstmate in Cursor

Open this repository in Cursor and start an agent session from the native agents panel with `AGENTS.md` as your instruction surface.
C0 teaches firstmate to detect the Cursor harness for itself and recognize Cursor's `agent-exec` process for the per-home session lock.
Cursor is still not a crewmate or secondmate adapter, so crew and secondmate dispatch require a verified dispatch harness in `config/crew-harness` until Cursor-native spawn is verified end to end.
Later tracks add Cursor-format hooks, MCP, and deeper native integration; this C0 scaffold is the packaging layer that makes Customize installation possible.
