import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const MCP_ROOT = path.resolve(SCRIPT_DIR, "..", "..");
const SERVER_ENTRY = path.join(MCP_ROOT, "dist", "src", "index.js");

async function main(): Promise<void> {
  const fmHome = process.env.FM_HOME?.trim();
  const env: Record<string, string> = {};
  if (fmHome) {
    env.FM_HOME = fmHome;
  }

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER_ENTRY],
    env,
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
