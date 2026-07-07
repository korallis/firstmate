import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const MCP_ROOT = path.resolve(SCRIPT_DIR, "..", "..");
const WORKSPACE_FOLDER = path.dirname(MCP_ROOT);
const MANIFEST_PATH = path.join(MCP_ROOT, "mcp.json");

type ManifestServer = {
  command: string;
  args: string[];
  env: Record<string, string>;
};

async function main(): Promise<void> {
  const server = await readManifestServer();

  const transport = new StdioClientTransport({
    command: server.command,
    args: server.args,
    env: server.env,
  });
  const client = new Client({ name: "firstmate-mcp-smoke", version: "0.1.0" });
  await client.connect(transport);

  const listed = await client.listTools();
  const names = listed.tools.map((tool) => tool.name).sort();
  const expected = [
    "backlog",
    "crew_state",
    "fleet_status",
    "peek_task",
    "steer_task",
  ];
  for (const name of expected) {
    if (!names.includes(name)) {
      throw new Error(`missing tool ${name}; got ${names.join(", ")}`);
    }
  }

  const fleet = await client.callTool({ name: "fleet_status", arguments: {} });
  const fleetText = extractText(fleet);
  if (!fleetText.includes("backlog")) {
    throw new Error("fleet_status did not include backlog content");
  }

  const backlog = await client.callTool({ name: "backlog", arguments: {} });
  const backlogText = extractText(backlog);
  if (backlogText.length < 1) {
    throw new Error("backlog tool returned empty body");
  }

  await client.close();
  console.log(`smoke ok: ${names.join(", ")}`);
}

async function readManifestServer(): Promise<ManifestServer> {
  const parsed = JSON.parse(await readFile(MANIFEST_PATH, "utf8")) as unknown;
  const manifest = requireRecord(parsed, "mcp.json");
  const mcpServers = requireRecord(manifest.mcpServers, "mcpServers");
  const firstmate = requireRecord(mcpServers.firstmate, "mcpServers.firstmate");
  const command = interpolateManifestValue(
    requireString(firstmate.command, "mcpServers.firstmate.command"),
  );
  const args = requireStringArray(
    firstmate.args,
    "mcpServers.firstmate.args",
  ).map(interpolateManifestValue);
  const env = readManifestEnv(firstmate.env);

  return { command, args, env };
}

function readManifestEnv(value: unknown): Record<string, string> {
  if (value === undefined) {
    return {};
  }

  const record = requireRecord(value, "mcpServers.firstmate.env");
  const env: Record<string, string> = {};
  for (const [key, rawValue] of Object.entries(record)) {
    const template = requireString(rawValue, `mcpServers.firstmate.env.${key}`);
    const resolved = interpolateManifestValue(template);
    if (resolved) {
      env[key] = resolved;
    }
  }
  return env;
}

function interpolateManifestValue(value: string): string {
  return value.replace(/\$\{workspaceFolder\}/g, WORKSPACE_FOLDER).replace(
    /\$\{env:([A-Za-z_][A-Za-z0-9_]*)\}/g,
    (_match, name: string): string => process.env[name]?.trim() ?? "",
  );
}

function requireRecord(
  value: unknown,
  label: string,
): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length < 1) {
    throw new Error(`${label} must be a nonempty string`);
  }
  return value;
}

function requireStringArray(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new Error(`${label} must be a string array`);
  }
  return value;
}

function extractText(result: { content?: unknown }): string {
  if (!Array.isArray(result.content)) {
    return "";
  }
  return result.content
    .map((item) => {
      if (
        typeof item === "object" &&
        item !== null &&
        "type" in item &&
        item.type === "text" &&
        "text" in item &&
        typeof item.text === "string"
      ) {
        return item.text;
      }
      return "";
    })
    .join("\n");
}

main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error(`smoke failed: ${message}`);
  process.exit(1);
});
