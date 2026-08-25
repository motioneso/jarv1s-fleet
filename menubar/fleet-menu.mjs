#!/usr/bin/env node
// Prints a SwiftBar menu describing the state of the fleet.
// Read-only: this script never writes to the state directory and never
// makes a network call. On any internal problem it still prints a valid
// menu (never crashes) whose first row explains the problem in plain
// English.
//
// Usage: JARV1S_FLEET_STATE=<dir> node fleet-menu.mjs

import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const WORKING_COLOR = "#00cdcd";
const WAITING_COLOR = "#e5c07b";
const DONE_COLOR = "green";
const GRAY_COLOR = "gray";
const ALARM_COLOR = "red";

const DONE_HIDE_AFTER_MS = 12 * 60 * 60 * 1000; // 12 hours
const ALARM_WINDOW_MS = 60 * 60 * 1000; // 1 hour
const LOG_TAIL_LINES = 200;

function stateDir() {
  return process.env.JARV1S_FLEET_STATE || path.join(os.homedir(), ".local/state/jarv1s-fleet");
}

// Remove characters that would break the "text | key=value" line grammar,
// and keep every row to a single line.
function sanitize(text) {
  return String(text ?? "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\|/g, "-")
    .trim();
}

function trim(text, max) {
  const s = sanitize(text);
  if (s.length <= max) return s;
  return s.slice(0, Math.max(0, max - 1)).trimEnd() + "…";
}

function line(text, params) {
  const parts = [sanitize(text)];
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined || v === null || v === "") continue;
      parts.push(`${k}=${v}`);
    }
  }
  return parts.join(" | ");
}

function ageShort(ms) {
  if (!Number.isFinite(ms) || ms < 0) ms = 0;
  const totalMin = Math.floor(ms / 60000);
  if (totalMin < 60) return `${totalMin}m`;
  const totalHours = Math.floor(totalMin / 60);
  if (totalHours < 24) return `${totalHours}h`;
  const days = Math.floor(totalHours / 24);
  return `${days}d`;
}

function ageLong(ms) {
  if (!Number.isFinite(ms) || ms < 0) ms = 0;
  const totalMin = Math.floor(ms / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  return h > 0 ? `${h}h ${m}m ago` : `${m}m ago`;
}

function hhmm(date) {
  const h = String(date.getHours()).padStart(2, "0");
  const m = String(date.getMinutes()).padStart(2, "0");
  return `${h}:${m}`;
}

function isReslicedBlock(task) {
  return (
    task.status === "blocked" &&
    typeof task.blocked_reason === "string" &&
    task.blocked_reason.startsWith("re-sliced")
  );
}

function isWaitingOnHuman(task) {
  return task.status === "blocked" && !isReslicedBlock(task) && !task.paused;
}

function loadTasks(dir) {
  const tasksDir = path.join(dir, "tasks");
  let files = [];
  try {
    files = fs.readdirSync(tasksDir).filter((f) => f.endsWith(".json"));
  } catch {
    return []; // no tasks directory yet: an empty fleet, not an error
  }
  const tasks = [];
  for (const f of files) {
    try {
      const raw = fs.readFileSync(path.join(tasksDir, f), "utf8");
      const t = JSON.parse(raw);
      if (t && typeof t === "object") tasks.push(t);
    } catch {
      // one bad record should not take down the whole menu
    }
  }
  return tasks;
}

// Reads only the tail of the log so we never scan an unbounded file.
function loadRecentAlarms(dir, now) {
  const logPath = path.join(dir, "log.jsonl");
  let raw;
  try {
    raw = fs.readFileSync(logPath, "utf8");
  } catch {
    return [];
  }
  const allLines = raw.split("\n").filter(Boolean);
  const tail = allLines.slice(-LOG_TAIL_LINES);
  const seen = new Set();
  const alarms = [];
  for (const l of tail) {
    let entry;
    try {
      entry = JSON.parse(l);
    } catch {
      continue;
    }
    const msg = entry && entry.msg;
    if (typeof msg !== "string" || !msg.includes("ALARM")) continue;
    const ts = new Date(entry.ts);
    if (Number.isNaN(ts.getTime())) continue;
    if (now - ts.getTime() > ALARM_WINDOW_MS) continue;
    const cleaned = msg.replace(/^ALARM:\s*/i, "ALARM ");
    const key = cleaned;
    if (seen.has(key)) continue;
    seen.add(key);
    alarms.push({ text: cleaned, ts });
  }
  // Most recent first, capped at 3.
  alarms.sort((a, b) => b.ts - a.ts);
  return alarms.slice(0, 3);
}

function loadSpawnCount(dir) {
  try {
    const raw = fs.readFileSync(path.join(dir, ".spawn-count"), "utf8").trim();
    if (!raw) return 0;
    // The file may hold a bare count, or "<cutoff-epoch> <count>" -
    // the count we want is always the last whitespace-separated field.
    const parts = raw.split(/\s+/);
    const n = parseInt(parts[parts.length - 1], 10);
    return Number.isFinite(n) ? n : 0;
  } catch {
    return 0;
  }
}

function loadSpawnCap(dir) {
  try {
    const raw = fs.readFileSync(path.join(dir, "settings.json"), "utf8");
    const settings = JSON.parse(raw);
    const cap = settings && settings.spawnBudget;
    return Number.isFinite(cap) ? cap : null;
  } catch {
    return null;
  }
}

function loadRunStarted(dir) {
  try {
    const st = fs.statSync(path.join(dir, "run-started"));
    return st.mtime;
  } catch {
    return null;
  }
}

function prUrlFromSpec(spec, pr) {
  if (typeof spec !== "string" || !spec.startsWith("http")) return null;
  if (!spec.includes("/issues/")) return null;
  const base = spec.split("/issues/")[0];
  return `${base}/pull/${pr}`;
}

function specHref(spec) {
  return typeof spec === "string" && spec.startsWith("http") ? spec : undefined;
}

// Statuses that mean a lane is actively being worked right now. "queued"
// is deliberately left out: a lane waiting its turn in the backlog is not
// "working" for the title count, and can flood the dropdown if shown one
// row per lane (this box can carry ~200 queued lanes at once).
const ACTIVE_STATUSES = new Set([
  "building",
  "relaying",
  "qa",
  "qa-green",
  "pr-open",
  "ci-fix",
  "merging",
]);
const QUEUED_INLINE_LIMIT = 5;

function buildMenu(dir) {
  const now = Date.now();
  const tasks = loadTasks(dir);

  const workingTasks = tasks.filter((t) => ACTIVE_STATUSES.has(t.status));
  const waitingTasks = tasks.filter(isWaitingOnHuman);

  const workingCount = workingTasks.length;
  const waitingCount = waitingTasks.length;

  const out = [];
  const title = waitingCount > 0 ? `Fleet ${workingCount} !${waitingCount}` : `Fleet ${workingCount}`;
  out.push(line(title));
  out.push("---");

  if (waitingCount > 0) {
    out.push(line("WAITING ON YOU", { color: WAITING_COLOR }));
    for (const t of waitingTasks) {
      const reason = trim(t.blocked_reason || "needs a decision", 70);
      out.push(
        line(`#${t.issue} ${reason}`, { color: WAITING_COLOR, href: specHref(t.spec) })
      );
    }
    out.push("---");
  }

  const notDoneOld = tasks.filter((t) => {
    if (t.status !== "done") return true;
    const updated = new Date(t.updated_at);
    if (Number.isNaN(updated.getTime())) return true;
    return now - updated.getTime() <= DONE_HIDE_AFTER_MS;
  });

  // Queued lanes are backlog, not active work - listing every one of them
  // floods the dropdown (this box can carry ~200 at once), so collapse
  // them into a single summary row unless there are only a few.
  const queued = notDoneOld.filter((t) => t.status === "queued");
  const showQueuedInline = queued.length <= QUEUED_INLINE_LIMIT;
  const visible = notDoneOld.filter((t) => t.status !== "queued" || showQueuedInline);

  visible.sort((a, b) => {
    const ad = new Date(a.updated_at).getTime() || 0;
    const bd = new Date(b.updated_at).getTime() || 0;
    return bd - ad;
  });

  for (const t of visible) {
    const updated = new Date(t.updated_at);
    const age = Number.isNaN(updated.getTime()) ? "" : ageShort(now - updated.getTime());
    const titleTrimmed = trim(t.title || "(no title)", 45);

    if (isReslicedBlock(t)) {
      out.push(
        line(`#${t.issue} split into a follow-up (issue #${t.resliced_to})`, {
          color: GRAY_COLOR,
          href: specHref(t.spec),
        })
      );
      continue;
    }

    let color;
    let statusText = t.status;
    if (t.paused) {
      color = GRAY_COLOR;
      statusText = `${t.status} (paused)`;
    } else if (t.status === "done") {
      color = DONE_COLOR;
    } else if (isWaitingOnHuman(t)) {
      color = WAITING_COLOR;
    } else if (ACTIVE_STATUSES.has(t.status)) {
      color = WORKING_COLOR;
    } else {
      // Includes queued lanes shown individually because there are few of
      // them, and any other status not covered above.
      color = GRAY_COLOR;
    }

    out.push(
      line(`#${t.issue} ${statusText} ${age} - ${titleTrimmed}`, {
        color,
        href: specHref(t.spec),
      })
    );

    if (t.pr) {
      const prUrl = prUrlFromSpec(t.spec, t.pr);
      out.push(line(`-- PR #${t.pr}`, { href: prUrl }));
    }
  }

  if (!showQueuedInline) {
    out.push(line(`${queued.length} more queued`, { color: GRAY_COLOR }));
  }

  out.push("---");

  const spawnCount = loadSpawnCount(dir);
  const spawnCap = loadSpawnCap(dir);
  out.push(line(`Agent starts ${spawnCount}${spawnCap !== null ? `/${spawnCap}` : ""}`));

  const runStarted = loadRunStarted(dir);
  if (runStarted) {
    out.push(line(`Run started ${hhmm(runStarted)} (${ageLong(now - runStarted.getTime())})`));
  }

  const alarms = loadRecentAlarms(dir, now);
  for (const a of alarms) {
    out.push(line(`${trim(a.text, 70)} (${hhmm(a.ts)})`, { color: ALARM_COLOR }));
  }

  return out.join("\n");
}

function fallbackMenu(reason) {
  return [
    line("Fleet ?"),
    "---",
    line(`Cannot read the fleet's status: ${sanitize(reason)}`, { color: ALARM_COLOR }),
    line("Check that the fleet state directory exists and is readable."),
  ].join("\n");
}

function main() {
  const dir = stateDir();
  try {
    if (!fs.existsSync(dir)) {
      console.log(fallbackMenu(`state directory not found (${dir})`));
      return;
    }
    console.log(buildMenu(dir));
  } catch (err) {
    console.log(fallbackMenu(err && err.message ? err.message : String(err)));
  }
}

main();
