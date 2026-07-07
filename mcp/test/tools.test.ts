import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import {
  buildFleetStatus,
  createFleetDeps,
  crewState,
  peekTask,
  readBacklog,
  steerTask,
  type FleetDeps,
  type ScriptResult,
} from "../src/fleet.js";
import type { FmPaths } from "../src/paths.js";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.resolve(TEST_DIR, "..", "..", "test", "fixtures");

function fixturePaths(): FmPaths {
  return {
    fmRoot: FIXTURE_ROOT,
    fmHome: FIXTURE_ROOT,
    binDir: path.join(FIXTURE_ROOT, "bin"),
    stateDir: FIXTURE_ROOT,
    dataDir: FIXTURE_ROOT,
    backlogPath: path.join(FIXTURE_ROOT, "backlog.md"),
  };
}

function mockDeps(
  runScript: FleetDeps["runScript"],
): FleetDeps {
  const paths = fixturePaths();
  return {
    paths,
    readText: async (filePath: string) => {
      const { readFile } = await import("node:fs/promises");
      return readFile(filePath, "utf8");
    },
    listMeta: async (stateDir: string) => {
      const { readdir } = await import("node:fs/promises");
      const entries = await readdir(stateDir);
      return entries.filter((name) => name.endsWith(".meta")).sort();
    },
    runScript,
  };
}

describe("read tools", () => {
  it("backlog returns fixture backlog", async () => {
    const text = await readBacklog(mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 })));
    assert.match(text, /demo-task-a1/);
    assert.match(text, /demo-queued-b2/);
  });

  it("fleet_status summarizes backlog and meta", async () => {
    const text = await buildFleetStatus(
      mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 })),
    );
    assert.match(text, /## backlog.md/);
    assert.match(text, /demo-task-a1/);
    assert.match(text, /window=fm:demo-task-a1/);
    assert.match(text, /kind=ship/);
  });

  it("peek_task wraps fm-peek.sh", async () => {
    const calls: string[][] = [];
    const text = await peekTask(
      mockDeps(async (_script, args) => {
        calls.push(args);
        return { stdout: "pane tail\n", stderr: "", exitCode: 0 };
      }),
      "demo-task-a1",
      12,
    );
    assert.equal(text, "pane tail");
    assert.deepEqual(calls, [["fm-demo-task-a1", "12"]]);
  });

  it("crew_state wraps fm-crew-state.sh", async () => {
    const calls: string[][] = [];
    const text = await crewState(
      mockDeps(async (_script, args) => {
        calls.push(args);
        return {
          stdout: "state: working · source: pane · busy\n",
          stderr: "",
          exitCode: 0,
        };
      }),
      "demo-task-a1",
    );
    assert.match(text, /state: working/);
    assert.deepEqual(calls, [["demo-task-a1"]]);
  });

  it("crew_state rejects unknown task ids", async () => {
    await assert.rejects(
      () =>
        crewState(
          mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 })),
          "unknown-task",
        ),
      /task_id not in fleet/,
    );
  });
});

describe("steer_task", () => {
  it("is the only script path that invokes fm-send.sh", async () => {
    const invoked: string[] = [];
    const calls: string[][] = [];
    const runScript = async (
      scriptName: string,
      args: string[],
    ): Promise<ScriptResult> => {
      invoked.push(scriptName);
      calls.push(args);
      return { stdout: "ok\n", stderr: "", exitCode: 0 };
    };
    const deps = mockDeps(runScript);
    await steerTask(deps, "demo-task-a1", "continue");
    assert.deepEqual(invoked, ["fm-send.sh"]);
    assert.deepEqual(calls, [["fm-demo-task-a1", "continue"]]);
  });

  it("rejects escape-hatch session targets", async () => {
    const deps = mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 }));
    await assert.rejects(
      () => steerTask(deps, "session:0:1.2", "hello"),
      /target not in fleet/,
    );
  });

  it("rejects unknown bare targets", async () => {
    const deps = mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 }));
    await assert.rejects(
      () => peekTask(deps, "random-pane"),
      /target not in fleet/,
    );
  });

  it("accepts meta window values", async () => {
    const calls: string[][] = [];
    const deps = mockDeps(async (_script, args) => {
      calls.push(args);
      return { stdout: "ok\n", stderr: "", exitCode: 0 };
    });
    await peekTask(deps, "fm:demo-task-a1");
    assert.deepEqual(calls, [["fm:demo-task-a1"]]);
  });

  it("rejects multiline steer lines", async () => {
    const deps = mockDeps(async () => ({ stdout: "", stderr: "", exitCode: 0 }));
    await assert.rejects(
      () => steerTask(deps, "demo-task-a1", "line one\nline two"),
      /single line without newlines/,
    );
  });
});

describe("createFleetDeps", () => {
  it("wires real read helpers", () => {
    const deps = createFleetDeps(fixturePaths());
    assert.equal(deps.paths.fmHome, FIXTURE_ROOT);
  });
});
