import { access, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SRC_DIR = path.dirname(fileURLToPath(import.meta.url));
const MCP_DIR = path.resolve(SRC_DIR, "..", "..");

export interface FmPaths {
  fmRoot: string;
  fmHome: string;
  binDir: string;
  stateDir: string;
  dataDir: string;
  backlogPath: string;
}

/** Resolve firstmate repo root from this package location (parent of mcp/). */
export function resolveFmRoot(): string {
  return path.resolve(MCP_DIR, "..");
}

/** Operational home: FM_HOME when set, else FM_ROOT, matching bin/fm-*.sh. */
export function resolveFmHome(fmRoot: string): string {
  const override = process.env.FM_HOME?.trim();
  if (override) {
    return path.resolve(override);
  }
  const rootOverride = process.env.FM_ROOT_OVERRIDE?.trim();
  if (rootOverride) {
    return path.resolve(rootOverride);
  }
  return fmRoot;
}

export function resolveFmPaths(fmRoot = resolveFmRoot()): FmPaths {
  const fmHome = resolveFmHome(fmRoot);
  const stateOverride = process.env.FM_STATE_OVERRIDE?.trim();
  const stateDir = stateOverride
    ? path.resolve(stateOverride)
    : path.join(fmHome, "state");
  const dataDir = path.join(fmHome, "data");
  return {
    fmRoot,
    fmHome,
    binDir: path.join(fmRoot, "bin"),
    stateDir,
    dataDir,
    backlogPath: path.join(dataDir, "backlog.md"),
  };
}

export async function pathExists(target: string): Promise<boolean> {
  try {
    await access(target);
    return true;
  } catch {
    return false;
  }
}

export async function readTextFile(target: string): Promise<string> {
  return readFile(target, "utf8");
}

export async function listMetaFiles(stateDir: string): Promise<string[]> {
  if (!(await pathExists(stateDir))) {
    return [];
  }
  const entries = await readdir(stateDir);
  return entries
    .filter((name) => name.endsWith(".meta"))
    .sort((a, b) => a.localeCompare(b));
}

export function parseMetaFile(content: string): Record<string, string> {
  const fields: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const eq = trimmed.indexOf("=");
    if (eq <= 0) {
      continue;
    }
    const key = trimmed.slice(0, eq);
    const value = trimmed.slice(eq + 1);
    fields[key] = value;
  }
  return fields;
}

export function metaTaskId(filename: string): string {
  return filename.replace(/\.meta$/, "");
}
