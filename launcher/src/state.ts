import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { BoardIssue, Lane, LoadResult, LogEntry, Settings } from "./types.js";

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

// Called when a run is (re)started. The header says "Tokens this run", so
// the running totals (kept in the token-usage folder) must restart from
// zero -- but the files themselves must survive. Each one remembers how far
// into every agent transcript the counter has read; deleting them loses
// those positions, and the next screen refresh re-reads whole old
// transcripts from the top and books all their history to the new run
// (seen live 2026-08-24: a fresh run opened claiming 1.1M tokens). So:
// zero the totals, keep the files, and fast-forward each read position to
// the end of its transcript so history stays history.
export function clearTokenCounts(dir: string): void {
  const usageDir = path.join(dir, "token-usage");
  let files: string[] = [];
  try {
    files = fs.readdirSync(usageDir).filter((name) => name.endsWith(".json"));
  } catch {
    return; // No totals yet: nothing to zero.
  }
  for (const name of files) {
    const file = path.join(usageDir, name);
    try {
      const sidecar = JSON.parse(fs.readFileSync(file, "utf8")) as {
        sessions?: Record<string, { offset?: number; usage?: unknown }>;
      };
      if (!sidecar || typeof sidecar !== "object") throw new Error("not a counter file");
      for (const [transcript, session] of Object.entries(sidecar.sessions ?? {})) {
        session.usage = { input: 0, output: 0, cacheRead: 0 };
        try {
          session.offset = fs.statSync(transcript).size;
        } catch {
          // Transcript gone: keep the old position; there is nothing left to read.
        }
      }
      atomicWrite(file, JSON.stringify(sidecar));
    } catch {
      // A garbled counter file carries no totals worth keeping.
      fs.rmSync(file, { force: true });
    }
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

// The daemon's snapshot of the board's Ready / In progress issues, written
// each time intake fetches the board. Missing or garbled reads as empty:
// the Ready tab then says the daemon has not looked yet.
function readBoardIssues(dir: string): BoardIssue[] {
  try {
    const value = readJson(path.join(dir, "board-issues.json"));
    if (!Array.isArray(value)) return [];
    return (value as BoardIssue[]).filter((row) => typeof row?.number === "number");
  } catch {
    return [];
  }
}

// The picker just changed an issue's run label on GitHub. The daemon's
// snapshot on disk is up to five minutes old, so without this the mark on
// screen would snap back to the old truth until the daemon's next read.
export function markBoardIssue(dir: string, issue: number, inRun: boolean): void {
  const file = path.join(dir, "board-issues.json");
  try {
    const stat = fs.statSync(file);
    const value = readJson(file);
    if (!Array.isArray(value)) return;
    atomicWrite(
      file,
      JSON.stringify(
        (value as BoardIssue[]).map((row) => (row?.number === issue ? { ...row, inRun } : row))
      )
    );
    // The daemon spaces its board reads by this file's clock; a mark change
    // is not a fresh read, so put the clock back where it was.
    fs.utimesSync(file, stat.atime, stat.mtime);
  } catch {
    // No snapshot yet: the daemon's next read will carry the new label anyway.
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
    boardIssues: readBoardIssues(dir),
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
  // One line per distinct message, keeping the newest occurrence: a stuck
  // condition raises the same alarm every minute, and repeating it once per
  // tick floods the screen without saying anything new.
  const newestByMessage = new Map<string, LogEntry>();
  for (const entry of logs) {
    if (entry.issue !== "fleet" || typeof entry.msg !== "string") continue;
    if (!entry.msg.startsWith("ALARM:")) continue;
    const timestamp = entry.ts ? Date.parse(entry.ts) : 0;
    if (timestamp < cutoff) continue;
    newestByMessage.set(entry.msg, entry);
  }
  return [...newestByMessage.values()];
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

// Tonight's agent-start count, read from the daemon's own counter file
// (".spawn-count": the window's start time in epoch seconds, then the count).
// That file is the authoritative number: the event log rotates at 10 MB, so
// counting "spawn" log lines undercounts after a rotation mid-run. Counting
// the log remains only as the fallback for a state folder the daemon has not
// written a counter into yet.
export function spawnsTonight(dir: string, logs: LogEntry[], now = new Date()): number {
  try {
    const parts = fs
      .readFileSync(path.join(dir, ".spawn-count"), "utf8")
      .trim()
      .split(/\s+/);
    const cutoff = Number(parts[0]);
    const count = Number(parts[1]);
    if (Number.isInteger(cutoff) && Number.isInteger(count) && count >= 0) {
      // The counter belongs to one night's window. If it matches the current
      // window it is tonight's count; if it is from an earlier night the
      // daemon just has not rolled it over yet, and tonight's count is zero.
      if (cutoff * 1000 === spawnWindowStart(now)) return count;
      return 0;
    }
  } catch {
    // No counter file: fall through to counting the log.
  }
  return spawnsSince(logs, now);
}
