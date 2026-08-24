import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Lane, LoadResult, LogEntry, Settings } from "./types.js";

export function stateDir(env = process.env): string {
  return env.JARV1S_FLEET_STATE || path.join(os.homedir(), ".local", "state", "jarv1s-fleet");
}

export function settingsPath(dir: string): string {
  return path.join(dir, "settings.json");
}

export function tasksPath(dir: string): string {
  return path.join(dir, "tasks");
}

function readJson(file: string): unknown {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function atomicWrite(file: string, value: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, value);
  fs.renameSync(tmp, file);
}

export function readSettings(dir: string): Settings | null {
  try {
    const value = readJson(settingsPath(dir));
    return value && typeof value === "object" ? (value as Settings) : null;
  } catch {
    return null;
  }
}

export function writeSettings(dir: string, settings: Settings): void {
  atomicWrite(settingsPath(dir), `${JSON.stringify(settings, null, 2)}\n`);
}

export function writeRunStarted(dir: string, now = new Date()): string {
  const value = now.toISOString();
  atomicWrite(path.join(dir, "run-started"), `${value}\n`);
  return value;
}

function readRunStarted(dir: string): string | null {
  try {
    return fs.readFileSync(path.join(dir, "run-started"), "utf8").trim() || null;
  } catch {
    return null;
  }
}

export function writeRunEnded(dir: string, now = new Date()): string {
  const value = now.toISOString();
  atomicWrite(path.join(dir, "run-ended"), `${value}\n`);
  return value;
}

// Called when a run is (re)started, so an old end-of-run stamp from a
// previous run does not make a brand new run look already finished.
export function clearRunEnded(dir: string): void {
  try {
    fs.rmSync(path.join(dir, "run-ended"));
  } catch {
    // Nothing to clear.
  }
}

function readRunEnded(dir: string): string | null {
  try {
    return fs.readFileSync(path.join(dir, "run-ended"), "utf8").trim() || null;
  } catch {
    return null;
  }
}

export function readLogs(dir: string): LogEntry[] {
  try {
    return fs
      .readFileSync(path.join(dir, "log.jsonl"), "utf8")
      .split("\n")
      .filter(Boolean)
      .flatMap((line) => {
        try {
          const value = JSON.parse(line);
          return value && typeof value === "object" ? [value as LogEntry] : [];
        } catch {
          return [];
        }
      });
  } catch {
    return [];
  }
}

export function loadState(dir: string): LoadResult {
  const lanes: Lane[] = [];
  const errors: Lane[] = [];
  try {
    for (const file of fs.readdirSync(tasksPath(dir)).filter((name) => name.endsWith(".json"))) {
      try {
        const value = readJson(path.join(tasksPath(dir), file));
        if (!value || typeof value !== "object" || typeof (value as Lane).issue !== "number") {
          throw new Error("lane record has no issue number");
        }
        lanes.push(value as Lane);
      } catch (error) {
        errors.push({
          issue: Number.parseInt(file, 10) || 0,
          error: error instanceof Error ? error.message : "malformed lane record"
        });
      }
    }
  } catch {
    // A missing or empty state folder is a normal pre-first-tick condition.
  }
  lanes.sort((a, b) => a.issue - b.issue);
  errors.sort((a, b) => a.issue - b.issue);
  return {
    lanes,
    errors,
    logs: readLogs(dir),
    runStarted: readRunStarted(dir),
    runEnded: readRunEnded(dir),
    settings: readSettings(dir)
  };
}

export function logsForLane(logs: LogEntry[], issue: number): LogEntry[] {
  return logs
    .filter((entry) => entry.issue === issue)
    .slice(-8)
    .reverse();
}

// Fleet-level alarms: things no single lane owns, such as a broken judge
// command or the terminal manager being unreachable. Mirrors the same
// hour-long cutoff fleetctl.mjs uses for the board, so this clears itself
// once nothing new is wrong.
export function fleetAlarms(logs: LogEntry[], now = new Date()): LogEntry[] {
  const cutoff = now.getTime() - 60 * 60 * 1000;
  return logs.filter((entry) => {
    if (entry.issue !== "fleet" || typeof entry.msg !== "string") return false;
    if (!entry.msg.startsWith("ALARM:")) return false;
    const timestamp = entry.ts ? Date.parse(entry.ts) : 0;
    return timestamp >= cutoff;
  });
}

export function spawnWindowStart(now = new Date()): number {
  const cutoff = new Date(now);
  cutoff.setHours(18, 0, 0, 0);
  if (now.getTime() < cutoff.getTime()) cutoff.setDate(cutoff.getDate() - 1);
  return cutoff.getTime();
}

export function spawnsSince(logs: LogEntry[], now = new Date()): number {
  const cutoff = spawnWindowStart(now);
  return logs.filter((entry) => {
    const timestamp = entry.ts ? Date.parse(entry.ts) : 0;
    return timestamp >= cutoff && entry.msg?.startsWith("spawn");
  }).length;
}
