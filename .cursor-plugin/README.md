# firstmate Cursor plugin (C0)

Installing this plugin from Cursor's Customize page wires firstmate's existing assets into your editor without copying them.

## What you get

- **Skills** from `.agents/skills` (afk, bearings, harness adapters, secondmate provisioning, and the rest of firstmate's internal skill library).

The plugin manifest only references paths that already live in the firstmate repo.
It does not duplicate skill or rule content.
Cursor-format hooks are deferred to a later track; Claude Code hooks remain in `.claude/settings.json` for non-plugin installs.

## Running firstmate in Cursor

Open this repository in Cursor and start an agent session from the native agents panel with `AGENTS.md` as your instruction surface.
firstmate detects the Cursor harness, treats itself as the captain's liaison, and uses the same `bin/` scripts, backlog, and supervision loop as a terminal-hosted firstmate home.
Later tracks add MCP and deeper Cursor-native integration; this C0 scaffold is the packaging layer that makes Customize installation possible.
