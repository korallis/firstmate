import path from "node:path";
import type { FleetDeps } from "./fleet.js";
import { metaTaskId, parseMetaFile } from "./paths.js";

export interface FleetTargetIndex {
  taskIds: Set<string>;
  allowedTargets: Set<string>;
  canonicalTargets: Map<string, string>;
  ambiguousTargets: Set<string>;
}

export const MAX_STEER_LINE_LENGTH = 500;

export async function loadFleetTargetIndex(
  deps: FleetDeps,
): Promise<FleetTargetIndex> {
  const taskIds = new Set<string>();
  const allowedTargets = new Set<string>();
  const canonicalTargets = new Map<string, string>();
  const ambiguousTargets = new Set<string>();
  const metaFiles = await deps.listMeta(deps.paths.stateDir);

  for (const file of metaFiles) {
    const id = metaTaskId(file);
    const canonicalTarget = `fm-${id}`;
    taskIds.add(id);
    allowedTargets.add(canonicalTarget);
    addCanonicalTarget(canonicalTargets, ambiguousTargets, id, canonicalTarget);
    addCanonicalTarget(
      canonicalTargets,
      ambiguousTargets,
      canonicalTarget,
      canonicalTarget,
    );

    const content = await deps.readText(
      path.join(deps.paths.stateDir, file),
    );
    const fields = parseMetaFile(content);
    if (fields.window) {
      allowedTargets.add(fields.window);
      addCanonicalTarget(
        canonicalTargets,
        ambiguousTargets,
        fields.window,
        canonicalTarget,
      );
    }
    if (fields.terminal) {
      allowedTargets.add(fields.terminal);
      addCanonicalTarget(
        canonicalTargets,
        ambiguousTargets,
        fields.terminal,
        canonicalTarget,
      );
    }
  }

  return { taskIds, allowedTargets, canonicalTargets, ambiguousTargets };
}

function addCanonicalTarget(
  canonicalTargets: Map<string, string>,
  ambiguousTargets: Set<string>,
  target: string,
  canonicalTarget: string,
): void {
  const existingTarget = canonicalTargets.get(target);
  if (existingTarget && existingTarget !== canonicalTarget) {
    canonicalTargets.delete(target);
    ambiguousTargets.add(target);
    return;
  }
  if (!ambiguousTargets.has(target)) {
    canonicalTargets.set(target, canonicalTarget);
  }
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
      "target not in fleet: backend escape-hatch selectors (session:...) are blocked; use a task id or recorded endpoint from state/*.meta",
    );
  }
  if (!index.allowedTargets.has(target)) {
    throw new Error(
      "target not in fleet: must be a task id or recorded endpoint value from state/*.meta",
    );
  }
  return target;
}

export function canonicalizeFleetScopedTarget(
  index: FleetTargetIndex,
  target: string,
): string {
  normalizeFleetScopedTarget(index, target);
  if (index.taskIds.has(target)) {
    return `fm-${target}`;
  }
  if (target.startsWith("fm-") && index.taskIds.has(target.slice(3))) {
    return target;
  }
  const canonicalTarget = index.canonicalTargets.get(target);
  if (!canonicalTarget) {
    if (index.ambiguousTargets.has(target)) {
      throw new Error(
        "target ambiguous: recorded by multiple state/*.meta files; use a task id",
      );
    }
    throw new Error(
      "target not in fleet: must be a task id or recorded endpoint value from state/*.meta",
    );
  }
  return canonicalTarget;
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
