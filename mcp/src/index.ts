#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio";
import { createFirstmateServer } from "./tools.js";
import { resolveFmPaths } from "./paths.js";

async function main(): Promise<void> {
  const paths = resolveFmPaths();
  const server = createFirstmateServer(paths);
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error(`firstmate-mcp failed: ${message}`);
  process.exit(1);
});
