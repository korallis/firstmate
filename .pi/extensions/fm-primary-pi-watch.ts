// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type RestartHandoff = {
  generation: string;
  previousPid: string;
  complete: boolean;
  stdout: string;
  stderr: string;
  code: number | null;
  reason: string;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const watchScript = `${fmRoot}/bin/fm-watch.sh`;
const wakeLib = `${fmRoot}/bin/fm-wake-lib.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const restartHandoffFile = `${state}/.pi-watch-restart-handoff`;
const watcherToolName = "fm_watch_arm_pi";
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function sessionOwnsLock(): boolean {
  return lockOwnership() === "owned";
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function recordedWatcherPid(): string {
  try {
    return readFileSync(`${state}/.watch.lock/pid`, "utf8").trim();
  } catch {
    return "";
  }
}

function healthyHomeWatcherPid(): string {
  const grace = process.env.FM_GUARD_GRACE || "300";
  const result = spawnSync(
    "bash",
    [
      "-c",
      '. "$1"; if fm_watcher_healthy "$2" "$3" "$4" "$5"; then printf "%s" "$FM_WATCHER_HEALTHY_PID"; fi',
      "_",
      wakeLib,
      state,
      watchScript,
      grace,
      fmHome,
    ],
    { encoding: "utf8" },
  );
  return result.status === 0 ? result.stdout.trim() : "";
}

async function replacementWatcherIsHealthy(previousPid: string): Promise<boolean> {
  if (!/^[1-9][0-9]*$/.test(previousPid) || previousPid === "1") return false;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const healthyPid = healthyHomeWatcherPid();
    if (healthyPid && healthyPid !== previousPid) return true;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  return false;
}

function readRestartHandoff(): RestartHandoff | null {
  try {
    return JSON.parse(readFileSync(restartHandoffFile, "utf8")) as RestartHandoff;
  } catch {
    return null;
  }
}

function writeRestartHandoff(handoff: RestartHandoff): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(restartHandoffFile, `${JSON.stringify(handoff)}\n`);
}

function completeRestartHandoff(generation: string, update: Omit<RestartHandoff, "generation" | "previousPid" | "complete">): void {
  const current = readRestartHandoff();
  if (!current || current.generation !== generation || current.complete) return;
  writeRestartHandoff({ ...current, ...update, complete: true });
}

function sameRestartHandoff(left: RestartHandoff, right: RestartHandoff): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function clearRestartHandoff(expected: RestartHandoff): void {
  const current = readRestartHandoff();
  if (!current || !sameRestartHandoff(current, expected)) return;
  try {
    unlinkSync(restartHandoffFile);
  } catch {}
}

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

export default function (pi: ExtensionAPI) {
  let child: any = null;
  let seq = 0;
  let apiActive = true;
  let stoppingForReload = false;
  let replacedWatcherPid = "";
  let toolSurfaceGuardRegistered = false;
  const generation = randomUUID();

  function keepWatcherToolActive(): void {
    if (!apiActive) return;
    const activeTools = pi.getActiveTools();
    if (activeTools.includes(watcherToolName)) return;
    pi.setActiveTools([...activeTools, watcherToolName]);
  }

  function stopArm(): void {
    if (child) child.kill("SIGTERM");
    child = null;
  }

  const cleanupOnProcessExit = () => {
    stopArm();
  };
  process.once("exit", cleanupOnProcessExit);

  async function sendWake(message: string): Promise<boolean> {
    if (!apiActive) return false;
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      { deliverAs: "followUp" },
    );
    return true;
  }

  async function reportPriorRestart(): Promise<void> {
    if (!sessionOwnsLock()) return;
    const deadline = Date.now() + 5000;
    let handoff = readRestartHandoff();
    if (!handoff) return;
    const priorGeneration = handoff.generation;
    while (!handoff.complete && apiActive && sessionOwnsLock() && Date.now() < deadline) {
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
      const current = readRestartHandoff();
      if (!current || current.generation !== priorGeneration) return;
      handoff = current;
    }
    if (!apiActive || !sessionOwnsLock()) return;
    if (!handoff.complete) {
      const failure = "watcher: FAILED - Pi reload arm handoff remained incomplete after 5s";
      if (await sendWake(failure) && sessionOwnsLock()) clearRestartHandoff(handoff);
      return;
    }
    if (handoff.reason) {
      if (await sendWake(handoff.reason) && sessionOwnsLock()) clearRestartHandoff(handoff);
      return;
    }
    if (handoff.code === 143 && await replacementWatcherIsHealthy(handoff.previousPid)) {
      if (apiActive && sessionOwnsLock()) clearRestartHandoff(handoff);
      return;
    }
    if (!apiActive || !sessionOwnsLock()) return;
    const failure = failureLine(handoff.stdout, handoff.stderr, handoff.code);
    if (failure && await sendWake(failure) && sessionOwnsLock()) clearRestartHandoff(handoff);
  }

  function startArm(): ArmResult {
    if (!sessionOwnsLock()) return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    markLoaded();
    if (child) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };
    const id = ++seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("close", async (code: number | null) => {
      child = null;
      const reason = actionableLine(`${stdout}\n${stderr}`);
      if (stoppingForReload) {
        completeRestartHandoff(generation, { stdout, stderr, code, reason });
        return;
      }
      const failure = reason ? "" : failureLine(stdout, stderr, code);
      if (!reason && !failure) return;
      try {
        await sendWake(reason || failure);
      } catch {
        // Pi owns delivery errors; fail open so the extension never wedges the session.
      }
    });
    child.on("error", async (error: Error) => {
      child = null;
      const failure = `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`;
      if (stoppingForReload) {
        completeRestartHandoff(generation, { stdout, stderr: failure, code: null, reason: "" });
        return;
      }
      try {
        await sendWake(failure);
      } catch {
        // Fail open.
      }
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("resources_discover", () => {
    keepWatcherToolActive();
    if (!toolSurfaceGuardRegistered) {
      toolSurfaceGuardRegistered = true;
      pi.on?.("before_agent_start", keepWatcherToolActive);
    }
  });
  pi.on?.("session_shutdown", (event: { reason?: string }) => {
    apiActive = false;
    stoppingForReload = event?.reason === "reload";
    if (stoppingForReload && child) {
      replacedWatcherPid = recordedWatcherPid();
      writeRestartHandoff({ generation, previousPid: replacedWatcherPid, complete: false, stdout: "", stderr: "", code: null, reason: "" });
    }
    stopArm();
    process.off("exit", cleanupOnProcessExit);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: watcherToolName,
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
  void reportPriorRestart().catch(() => {});
}
