import { McpServer } from "@modelcontextprotocol/server";
import * as z from "zod/v4";
import {
  buildFleetStatus,
  createFleetDeps,
  crewState,
  peekTask,
  readBacklog,
  steerTask,
  toolError,
  toolText,
} from "./fleet.js";
import type { FmPaths } from "./paths.js";

const READ_ONLY_ANNOTATION = {
  readOnlyHint: true,
  destructiveHint: false,
  openWorldHint: false,
};

const WRITE_ANNOTATION = {
  readOnlyHint: false,
  destructiveHint: false,
  openWorldHint: true,
};

export function registerFirstmateTools(
  server: McpServer,
  paths: FmPaths,
): void {
  const deps = createFleetDeps(paths);

  server.registerTool(
    "fleet_status",
    {
      title: "Fleet status",
      description:
        "Summarize in-flight tasks from state/*.meta and the full data/backlog.md. Read-only.",
      inputSchema: z.object({}),
      annotations: READ_ONLY_ANNOTATION,
    },
    async () => {
      try {
        return toolText(await buildFleetStatus(deps));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolError(`fleet_status failed: ${message}`);
      }
    },
  );

  server.registerTool(
    "peek_task",
    {
      title: "Peek task pane",
      description:
        "Wrap bin/fm-peek.sh for a fleet-scoped target (task id or window from state/*.meta). Read-only.",
      inputSchema: z.object({
        target: z
          .string()
          .min(1)
          .describe("Task id from state/*.meta or its recorded window= value"),
        lines: z
          .number()
          .int()
          .min(1)
          .max(200)
          .optional()
          .describe("Tail lines to capture (default 40)"),
      }),
      annotations: READ_ONLY_ANNOTATION,
    },
    async ({ target, lines }) => {
      try {
        return toolText(await peekTask(deps, target, lines));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolError(`peek_task failed: ${message}`);
      }
    },
  );

  server.registerTool(
    "crew_state",
    {
      title: "Crew current state",
      description:
        "Wrap bin/fm-crew-state.sh for a task id. Read-only one-line reconciled state.",
      inputSchema: z.object({
        task_id: z
          .string()
          .min(1)
          .describe("Firstmate task id from state/*.meta"),
      }),
      annotations: READ_ONLY_ANNOTATION,
    },
    async ({ task_id }) => {
      try {
        return toolText(await crewState(deps, task_id));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolError(`crew_state failed: ${message}`);
      }
    },
  );

  server.registerTool(
    "backlog",
    {
      title: "Backlog",
      description: "Read data/backlog.md verbatim. Read-only.",
      inputSchema: z.object({}),
      annotations: READ_ONLY_ANNOTATION,
    },
    async () => {
      try {
        return toolText(await readBacklog(deps));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolError(`backlog failed: ${message}`);
      }
    },
  );

  server.registerTool(
    "steer_task",
    {
      title: "Steer task (write)",
      description:
        "ONLY mutating tool: wrap bin/fm-send.sh with a single short line to a fleet-scoped target. Use sparingly.",
      inputSchema: z.object({
        target: z
          .string()
          .min(1)
          .describe("Task id from state/*.meta or its recorded window= value"),
        line: z
          .string()
          .min(1)
          .max(500)
          .describe("One-line steer text (no newlines, max 500 chars)"),
      }),
      annotations: WRITE_ANNOTATION,
    },
    async ({ target, line }) => {
      try {
        return toolText(await steerTask(deps, target, line));
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return toolError(`steer_task failed: ${message}`);
      }
    },
  );
}

export function createFirstmateServer(paths: FmPaths): McpServer {
  const server = new McpServer(
    { name: "firstmate", version: "0.1.0" },
    {
      instructions:
        "Read-first firstmate fleet tools. Prefer fleet_status, crew_state, peek_task, and backlog before steer_task. steer_task is the only write tool and wraps fm-send.sh.",
    },
  );
  registerFirstmateTools(server, paths);
  return server;
}
