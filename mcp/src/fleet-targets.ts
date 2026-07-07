import path from "node:path";
import type { FleetDeps } from "./fleet.js";
import { metaTaskId, parseMetaFile } from "./paths.js";

export interface FleetTargetIndex {
  taskIds: Set<string>;
  allowedTargets: Set<string>;
}

export const MAX_STEER_LINE_LENGTH = 500;

export async function loadFleetTargetIndex(
  deps: FleetDeps,
): Promise<FleetTargetIndex> {
  const taskIds = new Set<string>();
  const allowedTargets = new Set<string>();
  const metaFiles = await deps.listMeta(deps.paths.stateDir);

  for (const file of metaFiles) {
    const id = metaTaskId(file);
    taskIds.add(id);
    allowedTargets.add(`fm-${id}`);

    const content = await deps.readText(
      path.join(deps.paths.stateDir, file),
    );
    const fields = parseMetaFile(content);
    if (fields.window) {
      allowedTargets.add(fields.window);
    }
    if (fields.terminal) {
      allowedTargets.add(fields.terminal);
    }
  }

  return { taskIds, allowedTargets };
}

export function normalizeFleetScopedTarget(
  index: FleetTargetIndex,
  target: string,
): string {
  if (index.taskIds.has(target)) {
    return `fm-${target}`;
  }
  if (target.includes(":") && !index.allowedTargets.has(target)) {
    throw new Error(
      "target not in fleet: backend escape-hatch selectors (session:...) are blocked; use a task id or window from state/*.meta",
    );
  }
  if (!index.allowedTargets.has(target)) {
    throw new Error(
      "target not in fleet: must be a task id or window value from state/*.meta",
    );
  }
  return target;
}

export function assertFleetTaskId(
  index: FleetTargetIndex,
  taskId: string,
): void {
  if (!index.taskIds.has(taskId)) {
    throw new Error(
      "task_id not in fleet: must match a task id from state/*.meta",
    );
  }
}

export function assertSteerLine(line: string): void {
  if (line.includes("\n") || line.includes("\r")) {
    throw new Error("steer line must be a single line without newlines");
  }
  if (line.length > MAX_STEER_LINE_LENGTH) {
    throw new Error(
      `steer line exceeds ${MAX_STEER_LINE_LENGTH} characters`,
    );
  }
}
