import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Lane, Settings } from "./types.js";

export type TokenUsage = { input: number; output: number; cacheRead: number };

function zeroUsage(): TokenUsage {
  return { input: 0, output: 0, cacheRead: 0 };
}

function addUsage(a: TokenUsage, b: TokenUsage): TokenUsage {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cacheRead: a.cacheRead + b.cacheRead
  };
}

// Mirrors how the Claude program names the folder it writes a working
// directory's own session transcripts into: every "/" and "." in the
// directory's path becomes "-".
export function claudeProjectDir(cwd: string, homeDir = os.homedir()): string {
  return path.join(homeDir, ".claude", "projects", cwd.replace(/[/.]/g, "-"));
}

function listSessionFiles(cwd: string, homeDir: string): string[] {
  const dir = claudeProjectDir(cwd, homeDir);
  try {
    return fs
      .readdirSync(dir)
      .filter((name) => name.endsWith(".jsonl"))
      .map((name) => path.join(dir, name));
  } catch {
    return [];
  }
}

type SidecarSession = { offset: number; usage: TokenUsage };
type Sidecar = { sessions: Record<string, SidecarSession> };

function sidecarDir(stateDir: string): string {
  return path.join(stateDir, "token-usage");
}

function sidecarPath(stateDir: string, issue: number): string {
  return path.join(sidecarDir(stateDir), `${issue}.json`);
}

function loadSidecar(stateDir: string, issue: number): Sidecar {
  try {
    const value = JSON.parse(fs.readFileSync(sidecarPath(stateDir, issue), "utf8"));
    if (value && typeof value === "object" && value.sessions) return value as Sidecar;
  } catch {
    // No sidecar yet, or it is unreadable; start fresh rather than fail the whole view.
  }
  return { sessions: {} };
}

function saveSidecar(stateDir: string, issue: number, sidecar: Sidecar): void {
  const file = sidecarPath(stateDir, issue);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(sidecar));
  fs.renameSync(tmp, file);
}

// Reads only the bytes appended to a transcript since the last time it was
// read, so re-parsing the whole file on every screen refresh is not needed.
// A trailing partial line (the writer may be mid-flush) is left for the next
// read: newOffset only advances past complete lines.
export function readNewUsage(
  filePath: string,
  priorOffset: number
): { usage: TokenUsage; newOffset: number } {
  const size = fs.statSync(filePath).size;
  if (size <= priorOffset) return { usage: zeroUsage(), newOffset: priorOffset };
  const fd = fs.openSync(filePath, "r");
  const length = size - priorOffset;
  const buffer = Buffer.alloc(length);
  fs.readSync(fd, buffer, 0, length, priorOffset);
  fs.closeSync(fd);

  const usage = zeroUsage();
  let start = 0;
  let consumed = 0;
  while (true) {
    const newlineIndex = buffer.indexOf(0x0a, start);
    if (newlineIndex === -1) break;
    const line = buffer.toString("utf8", start, newlineIndex);
    start = newlineIndex + 1;
    consumed = start;
    if (line.trim()) {
      try {
        const entry = JSON.parse(line);
        const usageRecord = entry?.message?.usage;
        if (usageRecord && typeof usageRecord === "object") {
          usage.input +=
            (Number(usageRecord.input_tokens) || 0) +
            (Number(usageRecord.cache_creation_input_tokens) || 0);
          usage.output += Number(usageRecord.output_tokens) || 0;
          usage.cacheRead += Number(usageRecord.cache_read_input_tokens) || 0;
        }
      } catch {
        // A malformed or truncated line; skip it rather than fail the whole read.
      }
    }
  }
  return { usage, newOffset: priorOffset + consumed };
}

// Whether a lane's build agent runs under the Claude program, per the tool
// configured for its tier -- the only place this repo records which program
// built a lane. Lanes built by another program have no transcript to read.
export function isClaudeLane(lane: Lane, settings: Settings | null): boolean {
  const tier = lane.tier || "routine";
  return settings?.buildModels?.[tier]?.tool === "claude";
}

export type LaneTokens = { usage: TokenUsage; sessionCount: number };

// Sums every session transcript this lane has ever used, not just the one
// its worktree currently points at: a relay starts a new session without
// replacing the old one, and recovery spawns fix agents that write their
// own. The sidecar file remembers every session file seen for this lane, so
// a lane whose worktree has since been cleared (done, closed out) still
// reports what it spent.
export function laneTokenUsage(
  stateDir: string,
  lane: Lane,
  homeDir = os.homedir()
): LaneTokens {
  const sidecar = loadSidecar(stateDir, lane.issue);
  let changed = false;
  if (lane.worktree) {
    for (const file of listSessionFiles(lane.worktree, homeDir)) {
      if (!sidecar.sessions[file]) {
        sidecar.sessions[file] = { offset: 0, usage: zeroUsage() };
        changed = true;
      }
    }
  }

  let total = zeroUsage();
  for (const [file, session] of Object.entries(sidecar.sessions)) {
    if (fs.existsSync(file)) {
      const { usage, newOffset } = readNewUsage(file, session.offset);
      if (newOffset !== session.offset) {
        session.usage = addUsage(session.usage, usage);
        session.offset = newOffset;
        changed = true;
      }
    }
    total = addUsage(total, session.usage);
  }

  if (changed) saveSidecar(stateDir, lane.issue, sidecar);
  return { usage: total, sessionCount: Object.keys(sidecar.sessions).length };
}

export type FleetTokens = TokenUsage;

// The header total: Claude lanes only, so it never claims to know the spend
// of a program it cannot read a transcript for.
export function fleetTokenUsage(
  stateDir: string,
  lanes: Lane[],
  settings: Settings | null,
  homeDir = os.homedir()
): FleetTokens {
  let total = zeroUsage();
  for (const lane of lanes) {
    if (!isClaudeLane(lane, settings)) continue;
    total = addUsage(total, laneTokenUsage(stateDir, lane, homeDir).usage);
  }
  return total;
}

export function formatTokenCount(count: number): string {
  if (count < 1000) return String(count);
  if (count < 1_000_000) return `${(count / 1000).toFixed(1)}k`;
  return `${(count / 1_000_000).toFixed(1)}M`;
}

// The one-line label for a lane's own token spend: "not reported" for a
// lane run by another program (a zero there would read as free, which it
// is not -- it is simply unknown), a plain count for a Claude lane with
// nothing spent yet, and the fresh-input/output/cache split otherwise.
export function laneTokenLabel(
  stateDir: string,
  lane: Lane,
  settings: Settings | null,
  homeDir = os.homedir()
): string {
  if (!isClaudeLane(lane, settings)) return "tokens: not reported";
  const { usage } = laneTokenUsage(stateDir, lane, homeDir);
  if (usage.input === 0 && usage.output === 0 && usage.cacheRead === 0) return "tokens: none spent yet";
  const parts = [`${formatTokenCount(usage.input + usage.output)} tokens used`];
  if (usage.cacheRead > 0) parts.push(`${formatTokenCount(usage.cacheRead)} from cache`);
  return parts.join(", ");
}
