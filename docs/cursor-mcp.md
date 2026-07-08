# Cursor MCP server

`mcp/` is a small stdio MCP server for Cursor's native chat and agents panel.
It exposes live firstmate fleet state and one narrow steering tool.
It does not replace the firstmate lifecycle for session start, watcher supervision, spawning, merge approval, or teardown.
Use it as an operator surface for a firstmate home that already exists on disk.

## Setup

The checked-in manifest is [`mcp/mcp.json`](../mcp/mcp.json).
It registers one MCP server named `firstmate` and runs `npm --silent --prefix ${workspaceFolder}/mcp run start`.
Open this repository as the Cursor workspace so `${workspaceFolder}` resolves to the firstmate checkout that contains `mcp/`.

Install the package dependencies once before first use:

```sh
npm --prefix mcp install
```

The server requires Node 20 or newer.
`npm run start` builds the TypeScript package before launching `dist/src/index.js`, so Cursor can start it directly through the manifest after dependencies are installed.

## Operational Home

The MCP server always runs firstmate wrapper scripts from the checkout that contains `mcp/`.
By default it reads the repo root's `data/` and `state/` directories, matching a normal firstmate home.
Set `FM_HOME` in the MCP client environment when the panel should inspect a different firstmate home, such as a secondmate home.
`FM_STATE_OVERRIDE` can point at an alternate state directory for tests and smoke checks.
The manifest passes through `${env:FM_HOME}` and names `${workspaceFolder}/.env` as an optional env file for clients that support `envFile`.

## Tools

| Tool | Mutates? | Backing behavior |
| --- | --- | --- |
| `fleet_status` | No | Reads `data/backlog.md` and summarizes every `state/*.meta` task with its window, kind, harness, and project. |
| `backlog` | No | Reads `data/backlog.md` verbatim, or returns `(backlog absent)` when the file is missing. |
| `crew_state` | No | Wraps `bin/fm-crew-state.sh <task_id>` for a task id present in `state/*.meta`. |
| `peek_task` | No | Wraps `bin/fm-peek.sh` for a fleet-scoped target, with optional `lines` from 1 to 200 and the script's default 40 lines when omitted. |
| `steer_task` | Yes | Wraps `bin/fm-send.sh` with one short line to a fleet-scoped target. |

`steer_task` is the only mutating tool.
It changes a live agent conversation by sending exactly one line through firstmate's existing `fm-send.sh` path.
It does not spawn tasks, edit files, merge PRs, tear down worktrees, or bypass the captain approval rules.

## Target Scoping

`peek_task` and `steer_task` accept only targets already present in this home's fleet metadata.
A raw task id from `state/<id>.meta` is normalized to `fm-<id>`.
The explicit `fm-<id>` alias is accepted too.
Recorded endpoint values such as `window=` and Orca `terminal=` are accepted when they appear in that task's meta file.
Ad hoc backend selectors such as `session:...` are rejected unless they exactly match a recorded fleet endpoint.

`crew_state` is narrower by design and accepts only the task id from `state/<id>.meta`.
`steer_task.line` must be one line, must contain no newline characters, and is capped at 500 characters.

## Verification

Run the TypeScript build and fixture-backed unit tests from the package:

```sh
npm --prefix mcp test
```

Run the local MCP handshake smoke against the current `FM_HOME`:

```sh
npm --prefix mcp run smoke
```

The smoke client reads `mcp/mcp.json`, starts the stdio server, lists all five tools, and calls `fleet_status` plus `backlog`.
The repository behavior suite also includes [`tests/fm-mcp.test.sh`](../tests/fm-mcp.test.sh), which installs package dependencies, runs the package tests, and runs the smoke handshake.
