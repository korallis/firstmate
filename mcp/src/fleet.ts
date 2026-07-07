import { spawn } from "node:child_process";
import path from "node:path";
import {
  assertFleetScopedTarget,
  assertFleetTaskId,
  assertSteerLine,
  loadFleetTargetIndex,
} from "./fleet-targets.js";
import type { FmPaths } from "./paths.js";
import { listMetaFiles, parseMetaFile, readTextFile } from "./paths.js";

export interface ScriptResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export interface FleetDeps {
  paths: FmPaths;
  readText: (filePath: string) => Promise<string>;
  listMeta: (stateDir: string) => Promise<string[]>;
  runScript: (
    scriptName: string,
    args: string[],
    env?: NodeJS.ProcessEnv,
  ) => Promise<ScriptResult>;
}

export function createFleetDeps(paths: FmPaths): FleetDeps {
  return {
    paths,
    readText: readTextFile,
    listMeta: listMetaFiles,
    runScript: (scriptName, args, env) =>
      runBinScript(paths, scriptName, args, env),
  };
}

export function runBinScript(
  paths: FmPaths,
  scriptName: string,
  args: string[],
  extraEnv: NodeJS.ProcessEnv = {},
): Promise<ScriptResult> {
  const scriptPath = path.join(paths.binDir, scriptName);
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    FM_ROOT_OVERRIDE: paths.fmRoot,
    FM_HOME: paths.fmHome,
    FM_STATE_OVERRIDE: paths.stateDir,
    ...extraEnv,
  };

  return new Promise((resolve, reject) => {
    const child = spawn(scriptPath, args, {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        stdout,
        stderr,
        exitCode: code ?? 1,
      });
    });
  });
}

export async function readBacklog(deps: FleetDeps): Promise<string> {
  try {
    return await deps.readText(deps.paths.backlogPath);
  } catch {
    return "(backlog absent)\n";
  }
}

export async function buildFleetStatus(deps: FleetDeps): Promise<string> {
  const sections: string[] = [];
  sections.push(`fm_home: ${deps.paths.fmHome}`);
  sections.push("");
  sections.push("## backlog.md");
  sections.push(await readBacklog(deps));
  sections.push("");
  sections.push("## in-flight (state/*.meta)");
  const metaFiles = await deps.listMeta(deps.paths.stateDir);
  if (metaFiles.length === 0) {
    sections.push("(none)");
    return sections.join("\n");
  }
  for (const file of metaFiles) {
    const id = file.replace(/\.meta$/, "");
    const content = await deps.readText(
      path.join(deps.paths.stateDir, file),
    );
    const fields = parseMetaFile(content);
    const window = fields.window ?? "(no window)";
    const kind = fields.kind ?? "?";
    const project = fields.project ?? "?";
    const harness = fields.harness ?? "?";
    sections.push(`- ${id}: window=${window} kind=${kind} harness=${harness} project=${project}`);
  }
  return sections.join("\n");
}

export async function peekTask(
  deps: FleetDeps,
  target: string,
  lines?: number,
): Promise<string> {
  const index = await loadFleetTargetIndex(deps);
  assertFleetScopedTarget(index, target);
  const args = lines !== undefined ? [target, String(lines)] : [target];
  const result = await deps.runScript("fm-peek.sh", args);
  const body = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
  if (result.exitCode !== 0) {
    throw new Error(body || `fm-peek.sh exited ${result.exitCode}`);
  }
  return body || "(empty pane capture)";
}

export async function crewState(deps: FleetDeps, taskId: string): Promise<string> {
  const index = await loadFleetTargetIndex(deps);
  assertFleetTaskId(index, taskId);
  const result = await deps.runScript("fm-crew-state.sh", [taskId]);
  const body = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
  if (result.exitCode !== 0) {
    throw new Error(body || `fm-crew-state.sh exited ${result.exitCode}`);
  }
  return body;
}

export async function steerTask(
  deps: FleetDeps,
  target: string,
  line: string,
): Promise<string> {
  const index = await loadFleetTargetIndex(deps);
  assertFleetScopedTarget(index, target);
  assertSteerLine(line);
  const result = await deps.runScript("fm-send.sh", [target, line]);
  const body = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
  if (result.exitCode !== 0) {
    throw new Error(body || `fm-send.sh exited ${result.exitCode}`);
  }
  return body || `steered ${target}`;
}

export function toolText(content: string): { content: Array<{ type: "text"; text: string }> } {
  return { content: [{ type: "text", text: content }] };
}

export function toolError(message: string): { content: Array<{ type: "text"; text: string }>; isError: true } {
  return { content: [{ type: "text", text: message }], isError: true };
}
