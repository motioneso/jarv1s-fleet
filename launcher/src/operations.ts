import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Lane, Settings } from "./types.js";

const CLI = path.resolve(import.meta.dirname, "..", "..", "fleetctl.mjs");
const SERVICE_NAME = "jarv1s-fleet-tick";
const WATCHDOG_SERVICE_NAME = "jarv1s-fleet-watchdog";

function systemdQuote(value: string): string {
  return '"' + value.replaceAll("\\", "\\\\").replaceAll('"', '\\"') + '"';
}

function atomicWrite(file: string, contents: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = file + ".tmp-" + process.pid;
  fs.writeFileSync(temp, contents);
  fs.renameSync(temp, file);
}

export function serviceFiles(
  dir: string,
  configHome = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"),
  // Which product checkout the daemon builds in. Picked in setup and saved to
  // settings; the environment variable and the fallback folder only cover
  // settings written before that question existed.
  repo = process.env.JARV1S_REPO || path.join(os.homedir(), "jarv1s-fleet-run")
) {
  const systemdDir = path.join(configHome, "systemd", "user");
  const tick = path.resolve(import.meta.dirname, "..", "..", "tick.sh");
  const watchdog = path.resolve(import.meta.dirname, "..", "..", "fleet-watchdog.sh");
  return {
    service: path.join(systemdDir, SERVICE_NAME + ".service"),
    timer: path.join(systemdDir, SERVICE_NAME + ".timer"),
    serviceText:
      "[Unit]\nDescription=Jarv1s fleet daemon tick\n\n[Service]\nType=oneshot\nTimeoutStartSec=10min\nEnvironment=JARV1S_FLEET_STATE=" +
      systemdQuote(dir) +
      "\nEnvironment=JARV1S_REPO=" +
      systemdQuote(repo) +
      "\nExecStart=" +
      systemdQuote(tick) +
      "\nStandardOutput=journal\nStandardError=journal\nSyslogIdentifier=" +
      SERVICE_NAME +
      "\n",
    timerText:
      "[Unit]\nDescription=Run the Jarv1s fleet daemon tick every minute\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=1min\nAccuracySec=15s\n\n[Install]\nWantedBy=timers.target\n",
    // The watchdog is its own service unit, next to the tick one, so the two can be
    // enabled independently (same as the existing, currently-disabled coordinator
    // watchdog service this one was generalised from).
    watchdogService: path.join(systemdDir, WATCHDOG_SERVICE_NAME + ".service"),
    watchdogTimer: path.join(systemdDir, WATCHDOG_SERVICE_NAME + ".timer"),
    watchdogServiceText:
      "[Unit]\nDescription=Jarv1s fleet lane watchdog\n\n[Service]\nType=oneshot\nTimeoutStartSec=10min\nEnvironment=JARV1S_FLEET_STATE=" +
      systemdQuote(dir) +
      "\nExecStart=" +
      systemdQuote(watchdog) +
      "\nStandardOutput=journal\nStandardError=journal\nSyslogIdentifier=" +
      WATCHDOG_SERVICE_NAME +
      "\n",
    watchdogTimerText:
      "[Unit]\nDescription=Run the Jarv1s fleet lane watchdog every minute\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=1min\nAccuracySec=15s\n\n[Install]\nWantedBy=timers.target\n"
  };
}

export function installUserService(dir: string, repo?: string, configHome?: string): void {
  const files = serviceFiles(dir, configHome, repo);
  atomicWrite(files.service, files.serviceText);
  atomicWrite(files.timer, files.timerText);
  atomicWrite(files.watchdogService, files.watchdogServiceText);
  atomicWrite(files.watchdogTimer, files.watchdogTimerText);
  execFileSync("systemctl", ["--user", "daemon-reload"]);
}

function fleetctl(dir: string, ...args: string[]): string {
  return execFileSync("node", [CLI, ...args], {
    env: { ...process.env, JARV1S_FLEET_STATE: dir },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
}

export function setLane(dir: string, issue: number, ...fields: string[]): void {
  fleetctl(dir, "set", String(issue), ...fields);
}

// "fleet" is not a lane number: it is the whole run's own log, the same
// target fleetctl.mjs already accepts for fleet-level lines (the end-run
// note lands there too).
export function logLane(dir: string, issue: number | "fleet", message: string): void {
  fleetctl(dir, "log", String(issue), message);
}

export function rotateLog(dir: string): void {
  fleetctl(dir, "rotate-log");
}

export function daemonActive(): boolean {
  try {
    execFileSync("systemctl", ["--user", "is-active", "--quiet", "jarv1s-fleet-tick.timer"]);
    return true;
  } catch {
    return false;
  }
}

export function startDaemon(dir: string, repo?: string): void {
  installUserService(dir, repo);
  execFileSync("systemctl", ["--user", "enable", "--now", SERVICE_NAME + ".timer"]);
  execFileSync("systemctl", ["--user", "enable", "--now", WATCHDOG_SERVICE_NAME + ".timer"]);
}

// The exact systemctl calls the end-run action makes, pulled out so the
// self-check can verify both timers are targeted without needing a real
// systemd on the test box.
export function stopTimerCommands(): string[][] {
  return [
    ["systemctl", "--user", "disable", "--now", SERVICE_NAME + ".timer"],
    ["systemctl", "--user", "disable", "--now", WATCHDOG_SERVICE_NAME + ".timer"]
  ];
}

export function stopTimers(): void {
  for (const [command, ...args] of stopTimerCommands()) {
    try {
      execFileSync(command, args, { stdio: "ignore" });
    } catch {
      // Already stopped, or systemd is unreachable; end-run still proceeds either way.
    }
  }
}

// Closes the terminal pane for each named agent still running, for the
// "close their panes" choice at the end of a run. Best-effort: an agent
// already gone, or the terminal manager being unreachable, does not stop
// the rest from being closed.
export function closeAgentPanes(agentNames: string[]): void {
  if (agentNames.length === 0) return;
  let agents: Array<{ name?: string; pane_id?: string }> = [];
  try {
    agents =
      herdrJson<{ result?: { agents?: Array<{ name?: string; pane_id?: string }> } }>([
        "agent",
        "list"
      ])?.result?.agents ?? [];
  } catch {
    return;
  }
  for (const name of agentNames) {
    const pane = agents.find((entry) => entry?.name === name)?.pane_id;
    if (!pane) continue;
    try {
      execFileSync("herdr", ["pane", "close", pane], { stdio: "ignore" });
    } catch {
      // Best effort; move on to the next pane.
    }
  }
}

export function messageAgent(agent: string | null | undefined, message: string): void {
  if (agent) execFileSync("herdr", ["agent", "prompt", agent, message], { stdio: "ignore" });
}

export async function askJudge(
  settings: Settings,
  prompt: string,
  timeoutMs = 30000
): Promise<string> {
  return new Promise((resolve, reject) => {
    const command = String(settings.judgeCmd) + ' "$FLEET_JUDGE_PROMPT"';
    const child = spawn("/bin/sh", ["-c", command, "--"], {
      env: { ...process.env, FLEET_JUDGE_PROMPT: prompt },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("judgment call timed out"));
    }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => (stdout += chunk.toString()));
    child.stderr.on("data", (chunk: Buffer) => (stderr += chunk.toString()));
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (code === 0 && stdout.trim()) resolve(stdout.trim());
      else if (code === 0) reject(new Error("judgment command returned no answer"));
      else
        reject(
          new Error(stderr.trim() || "judgment command exited with " + String(code ?? "an error"))
        );
    });
  });
}

function shellQuote(value: string): string {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

// Lane agents share one tab so they never land in a tab a person is working in.
const AGENT_TAB_LABEL = process.env.FLEET_AGENT_TAB || "Fleet Agents";

type HerdrTabList = { result?: { tabs?: Array<{ label?: string; tab_id?: string }> } };
type HerdrPaneList = { result?: { panes?: Array<{ tab_id?: string; pane_id?: string }> } };
type HerdrPaneSplit = { result?: { pane_id?: string; pane?: { pane_id?: string } } };
type HerdrTabCreate = { result?: { root_pane?: { pane_id?: string } } };

function herdrJson<T>(args: string[]): T {
  return JSON.parse(execFileSync("herdr", args, { encoding: "utf8" })) as T;
}

// Each agent program spells "which model" and "how hard to think" its own way,
// and needs its own flag to run unattended. A program we do not know gets the
// model on a --model flag, the most common spelling.
export function launchArgs(tool: string, model: string, effort: string): string[] {
  if (tool === "codex")
    return [
      "-m",
      model,
      "-c",
      "model_reasoning_effort=" + effort,
      "-s",
      "danger-full-access",
      "-a",
      "never"
    ];
  if (tool === "claude")
    return ["--model", model, "--effort", effort, "--permission-mode", "bypassPermissions"];
  return ["--model", model];
}

// A pane in the shared agents tab: split one that is already there, or make the
// tab if this is the first agent.
function agentPane(cwd: string): string {
  const tabs = herdrJson<HerdrTabList>(["tab", "list"])?.result?.tabs ?? [];
  const tab = tabs.find((entry) => entry?.label === AGENT_TAB_LABEL);
  if (tab?.tab_id) {
    const panes = herdrJson<HerdrPaneList>(["pane", "list"])?.result?.panes ?? [];
    const base = panes.find((pane) => pane?.tab_id === tab.tab_id);
    if (base?.pane_id) {
      const split = herdrJson<HerdrPaneSplit>([
        "pane",
        "split",
        base.pane_id,
        "--direction",
        "down",
        "--cwd",
        cwd,
        "--no-focus"
      ]);
      const pane = split?.result?.pane_id ?? split?.result?.pane?.pane_id;
      if (pane) return pane;
    }
  }
  const created = herdrJson<HerdrTabCreate>([
    "tab",
    "create",
    "--cwd",
    cwd,
    "--label",
    AGENT_TAB_LABEL
  ]);
  const pane = created?.result?.root_pane?.pane_id;
  if (!pane) throw new Error("Herdr could not open a pane for the rescue agent");
  return pane;
}

function spawnRescueAgent(lane: Lane, settings: Settings, reading: string): void {
  const name = "fleet-rescue-" + lane.issue + "-" + Date.now();
  const worktree = lane.worktree || process.cwd();
  // The record CLI ships with this tooling, not with the product checkout the lane builds in.
  const fleetctlPath = path.resolve(import.meta.dirname, "..", "..", "fleetctl.mjs");
  const claim =
    "node " +
    shellQuote(fleetctlPath) +
    " set " +
    lane.issue +
    " status=building agent=" +
    name +
    " paused=false pausedAt=null pausedBy=null && node " +
    shellQuote(fleetctlPath) +
    " log " +
    lane.issue +
    " " +
    shellQuote("spawn: rescue agent " + name);
  const build = settings.buildModels[lane.tier || "routine"];
  if (!build?.model || !build.effort)
    throw new Error("No build model and effort are configured for this lane.");
  const tool = build.tool || "claude";
  const pane = agentPane(worktree);
  execFileSync(
    "herdr",
    [
      "agent",
      "start",
      name,
      "--kind",
      tool,
      "--pane",
      pane,
      "--",
      ...launchArgs(tool, build.model, build.effort),
      "You are rescuing issue #" +
        lane.issue +
        ". Your first action must be to run " +
        claim +
        ". Then continue under the normal fleet rules. The judgment call was:\n" +
        reading +
        "\nDo not touch production, delete data, rewrite history, disable checks, or merge unproven work."
    ],
    { stdio: "ignore" }
  );
}

export function acceptRescue(dir: string, lane: Lane, reading: string): void {
  logLane(dir, lane.issue, "human accepted the rescue preview");
  const settings = JSON.parse(fs.readFileSync(path.join(dir, "settings.json"), "utf8")) as Settings;
  spawnRescueAgent(lane, settings, reading);
}
