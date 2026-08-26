#!/usr/bin/env node
// fleetctl — CLI for the fleet daemon's task records (issue #1893).
//
// State lives outside the repo (default ~/.local/state/jarv1s-fleet/, override with
// JARV1S_FLEET_STATE). One JSON file per lane under tasks/<issue>.json, an append-only
// log.jsonl, and a generated board.md that Ben reads in the morning.
//
// Exit codes: 0 ok, 1 validation error, 2 usage error or missing record.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const STATUSES = [
  "queued",
  "building",
  "pr-open",
  "ci-red",
  "qa",
  "qa-red",
  "qa-green",
  "qa-too-big",
  "merging",
  "blocked",
  "done"
];

const TIERS = ["routine", "sensitive", "security"];

// Plain-English status labels for the board.
const STATUS_LABELS = {
  queued: "Waiting to start",
  building: "Being built",
  "pr-open": "PR open, waiting on checks",
  "ci-red": "Checks failing",
  qa: "In review",
  "qa-red": "Review found problems",
  "qa-green": "Review passed",
  "qa-too-big": "Review says too big; re-reviewing piece by piece",
  merging: "Merging",
  blocked: "Needs Ben",
  done: "Done"
};

const INT_FIELDS = new Set([
  "pr",
  "chunked_review",
  "relays",
  "qa_rounds",
  "ci_fix_rounds",
  "qa_fix_rounds",
  "judgment_attempts",
  "deputy_attempts",
  "merge_update_attempts",
  "merge_fix_rounds",
  "checks_rerun_requested",
  "checks_retriggers",
  "closeout_attempts",
  "worktree_attempts",
  "teardown_attempts",
  "reslice_attempted",
  "reslice_failures",
  "resliced_to",
  "relay_cap_waived",
  "idle_hold_since"
]);
const INCREMENT_FIELDS = new Set([
  "relays",
  "qa_rounds",
  "ci_fix_rounds",
  "qa_fix_rounds",
  "merge_fix_rounds",
  "reslice_failures"
]);
const BOOL_FIELDS = new Set(["paused"]);
const SETTABLE_FIELDS = new Set([
  "title",
  "chunked_review",
  "spec",
  "tier",
  "status",
  "branch",
  "worktree",
  "pr",
  "agent",
  "reviewer",
  "relays",
  "qa_rounds",
  "ci_fix_rounds",
  "qa_fix_rounds",
  "blocked_reason",
  "paused",
  "pausedAt",
  "pausedBy",
  "question",
  "questionAskedAt",
  "judgment_attempts",
  "judgment_answer",
  "judgment_at",
  "judgment_hold",
  "deputy_reason",
  "deputy_answer",
  "deputy_attempts",
  "deputy_at",
  "merge_update_attempts",
  "merge_fix_rounds",
  "checks_rerun_requested",
  "checks_retriggers",
  "closeout_attempts",
  "closeout_note",
  "worktree_attempts",
  "teardown_attempts",
  "reslice_attempted",
  "reslice_failures",
  "resliced_to",
  "relay_cap_waived",
  "fix_round_base",
  "idle_hold_since"
]);

class CliError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}

const usageError = (msg) => new CliError(msg, 2);
const validationError = (msg) => new CliError(msg, 1);

function stateDir() {
  return (
    process.env.JARV1S_FLEET_STATE || path.join(os.homedir(), ".local", "state", "jarv1s-fleet")
  );
}

function tasksDir() {
  return path.join(stateDir(), "tasks");
}

function recordPath(issue) {
  return path.join(tasksDir(), `${issue}.json`);
}

function logPath() {
  return path.join(stateDir(), "log.jsonl");
}

// Atomic write: temp file in the same directory, then rename.
function writeFileAtomic(filePath, contents) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = path.join(
    path.dirname(filePath),
    `.${path.basename(filePath)}.tmp-${process.pid}-${Date.now()}`
  );
  fs.writeFileSync(tmp, contents);
  fs.renameSync(tmp, filePath);
}

const LOG_ROTATE_BYTES = 10 * 1024 * 1024; // 10 MB

// Once the log passes 10 MB, the old file is kept beside the new one (as
// log.jsonl.1) instead of letting log.jsonl grow forever. This is checked
// before the write that would push it over, so a single line is never
// split across the rotation.
function rotateLogIfNeeded() {
  const file = logPath();
  let size = 0;
  try {
    size = fs.statSync(file).size;
  } catch {
    return;
  }
  if (size < LOG_ROTATE_BYTES) return;
  const old = `${file}.1`;
  try {
    fs.rmSync(old, { force: true });
  } catch {
    // ignore
  }
  fs.renameSync(file, old);
}

// Forces the same rotation rotateLogIfNeeded does at 10 MB, on demand --
// used when a human ends a run, so the next run starts against a clean log
// rather than waiting for it to grow that large again.
function forceRotateLog() {
  const file = logPath();
  if (!fs.existsSync(file)) return;
  const old = `${file}.1`;
  try {
    fs.rmSync(old, { force: true });
  } catch {
    // ignore
  }
  fs.renameSync(file, old);
}

function appendLog(issue, msg) {
  fs.mkdirSync(stateDir(), { recursive: true });
  rotateLogIfNeeded();
  const line = JSON.stringify({ ts: new Date().toISOString(), issue, msg });
  // Single O_APPEND write; appending via temp-and-rename would drop concurrent lines.
  fs.appendFileSync(logPath(), `${line}\n`);
}

function parseIssue(raw) {
  if (!raw || !/^\d+$/.test(raw)) {
    throw usageError(`expected an issue number, got "${raw ?? ""}"`);
  }
  return Number(raw);
}

function readRecord(issue) {
  const file = recordPath(issue);
  if (!fs.existsSync(file)) {
    throw usageError(`no record for issue ${issue} (${file})`);
  }
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeRecord(record) {
  writeFileAtomic(recordPath(record.issue), `${JSON.stringify(record, null, 2)}\n`);
}

function parsePairs(args) {
  const pairs = [];
  for (const arg of args) {
    const eq = arg.indexOf("=");
    if (eq <= 0) {
      throw usageError(`expected field=value, got "${arg}"`);
    }
    pairs.push([arg.slice(0, eq), arg.slice(eq + 1)]);
  }
  return pairs;
}

function validateTier(tier) {
  if (!TIERS.includes(tier)) {
    throw validationError(`tier must be one of ${TIERS.join(", ")}; got "${tier}"`);
  }
}

function cmdAdd(argv) {
  const issue = parseIssue(argv[0]);
  const fields = Object.fromEntries(parsePairs(argv.slice(1)));
  const extra = Object.keys(fields).filter((k) => k !== "spec" && k !== "tier");
  if (extra.length > 0) {
    throw usageError(`add only takes spec= and tier=; got ${extra.join(", ")}`);
  }
  if (!fields.spec || !fields.tier) {
    throw usageError("add requires spec=<path> and tier=<routine|sensitive|security>");
  }
  validateTier(fields.tier);
  if (fs.existsSync(recordPath(issue))) {
    throw validationError(`record for issue ${issue} already exists`);
  }
  const record = {
    issue,
    title: null,
    spec: fields.spec,
    tier: fields.tier,
    status: "queued",
    branch: null,
    worktree: null,
    pr: null,
    agent: null,
    reviewer: null,
    relays: 0,
    qa_rounds: 0,
    ci_fix_rounds: 0,
    qa_fix_rounds: 0,
    blocked_reason: null,
    paused: false,
    pausedAt: null,
    pausedBy: null,
    question: null,
    questionAskedAt: null,
    judgment_attempts: 0,
    judgment_answer: null,
    judgment_at: null,
    judgment_hold: null,
    deputy_reason: null,
    deputy_answer: null,
    deputy_attempts: 0,
    deputy_at: null,
    merge_update_attempts: 0,
    merge_fix_rounds: 0,
    checks_rerun_requested: 0,
    checks_retriggers: 0,
    closeout_attempts: 0,
    closeout_note: null,
    worktree_attempts: 0,
    updated_at: new Date().toISOString()
  };
  writeRecord(record);
  appendLog(issue, `added: tier=${fields.tier} spec=${fields.spec} status=queued`);
  process.stdout.write(`${JSON.stringify(record, null, 2)}\n`);
}

function cmdSet(argv) {
  const issue = parseIssue(argv[0]);
  const pairs = parsePairs(argv.slice(1));
  if (pairs.length === 0) {
    throw usageError("set requires at least one field=value pair");
  }
  const record = readRecord(issue);
  const changes = [];
  for (const [field, rawValue] of pairs) {
    if (!SETTABLE_FIELDS.has(field)) {
      throw validationError(`unknown field "${field}"`);
    }
    let value;
    if (rawValue === "+1") {
      if (!INCREMENT_FIELDS.has(field)) {
        throw validationError(`"+1" is only valid for relays, qa_rounds, ci_fix_rounds, qa_fix_rounds, and merge_fix_rounds, not ${field}`);
      }
      value = (record[field] ?? 0) + 1;
    } else if (BOOL_FIELDS.has(field)) {
      if (rawValue !== "true" && rawValue !== "false") {
        throw validationError(`${field} must be true or false; got "${rawValue}"`);
      }
      value = rawValue === "true";
    } else if (rawValue === "null" || rawValue === "") {
      value = null;
    } else if (INT_FIELDS.has(field)) {
      if (!/^\d+$/.test(rawValue)) {
        throw validationError(`${field} must be a number; got "${rawValue}"`);
      }
      value = Number(rawValue);
    } else {
      value = rawValue;
    }
    if (field === "status" && !STATUSES.includes(value)) {
      throw validationError(`status must be one of ${STATUSES.join(", ")}; got "${value}"`);
    }
    if (field === "tier" && value !== null) {
      validateTier(value);
    }
    record[field] = value;
    changes.push(`${field}=${value === null ? "null" : value}`);
  }
  record.updated_at = new Date().toISOString();
  writeRecord(record);
  appendLog(issue, `set ${changes.join(" ")}`);
  process.stdout.write(`${JSON.stringify(record, null, 2)}\n`);
}

function cmdGet(argv) {
  const issue = parseIssue(argv[0]);
  const record = readRecord(issue);
  process.stdout.write(`${JSON.stringify(record, null, 2)}\n`);
}

function readAllRecords() {
  const dir = tasksDir();
  if (!fs.existsSync(dir)) {
    return [];
  }
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")))
    .sort((a, b) => a.issue - b.issue);
}

function cmdList() {
  for (const r of readAllRecords()) {
    process.stdout.write(`${r.issue}\t${r.tier}\t${r.status}\t${r.pr ?? "-"}\t${r.updated_at}\n`);
  }
}

function cmdLog(argv) {
  const target = argv[0];
  const msg = argv.slice(1).join(" ").trim();
  if (!msg) {
    throw usageError("log requires a message");
  }
  // "fleet" is not a lane: it is the whole run's own log line (rate-limit
  // backoff, the stillness alarm, and similar things no single lane owns).
  if (target === "fleet") {
    appendLog("fleet", msg);
    return;
  }
  const issue = parseIssue(target);
  readRecord(issue); // fail with exit 2 if the record does not exist
  appendLog(issue, msg);
}

// Derive the GitHub web URL from the repo this script lives in, so #NN and PR numbers
// can be real links. Falls back to plain text when the remote is unreadable.
function repoWebUrl() {
  try {
    const repoDir = path.dirname(fileURLToPath(import.meta.url));
    const remote = execFileSync("git", ["-C", repoDir, "config", "--get", "remote.origin.url"], {
      encoding: "utf8"
    }).trim();
    const match = remote.match(/github\.com[:/]([^/]+)\/([^/\s]+?)(?:\.git)?$/);
    if (match) {
      return `https://github.com/${match[1]}/${match[2]}`;
    }
  } catch {
    // No git or no remote; plain text is fine.
  }
  return null;
}

function readLogLines() {
  const file = logPath();
  if (!fs.existsSync(file)) {
    return [];
  }
  return fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter((l) => l !== null);
}

function cmdBoard() {
  const records = readAllRecords();
  const webUrl = repoWebUrl();
  const issueLink = (n) => (webUrl ? `[#${n}](${webUrl}/issues/${n})` : `#${n}`);
  const prLink = (n) => (n == null ? "-" : webUrl ? `[#${n}](${webUrl}/pull/${n})` : `#${n}`);

  const lines = [];
  lines.push("# Fleet board");
  lines.push("");
  lines.push(`Generated ${new Date().toISOString()}.`);
  lines.push("");
  // Fleet-level alarms: things no single lane owns (GitHub gone silent,
  // a broken judge, and so on). Shown for an hour after the last time one
  // fired, so the banner clears itself once nothing new is wrong.
  const alarmCutoff = Date.now() - 60 * 60 * 1000;
  const alarms = readLogLines().filter(
    (l) =>
      l.issue === "fleet" &&
      typeof l.msg === "string" &&
      l.msg.startsWith("ALARM:") &&
      Date.parse(l.ts ?? "") >= alarmCutoff
  );
  if (alarms.length > 0) {
    lines.push("## Alerts");
    lines.push("");
    for (const l of alarms) {
      lines.push(`- ${l.ts} ${l.msg.replace(/^ALARM:\s*/, "")}`);
    }
    lines.push("");
  }
  // Run complete: every lane is finished and there's nothing left to do
  // until new work shows up on GitHub. Worked out live from the current
  // records rather than from a stored flag, so it can never go stale.
  if (records.length > 0 && records.every((r) => r.status === "done" || r.status === "blocked")) {
    lines.push(
      "Run complete: every lane is done or parked. Checking GitHub for new work every tenth tick from here, not every tick."
    );
    lines.push("");
  }
  lines.push("| Issue | Tier | Status | PR | Relays | QA rounds | Blocked because |");
  lines.push("| --- | --- | --- | --- | --- | --- | --- |");
  for (const r of records) {
    lines.push(
      `| ${issueLink(r.issue)} | ${r.tier} | ${STATUS_LABELS[r.status] ?? r.status} | ` +
        `${prLink(r.pr)} | ${r.relays} | ${r.qa_rounds} | ${r.blocked_reason ?? "-"} |`
    );
  }
  if (records.length === 0) {
    lines.push("| - | - | - | - | - | - | - |");
  }
  lines.push("");
  // Lanes the daemon marked done anyway after three failed attempts to close
  // them out on GitHub -- the daemon's records and the board are allowed to
  // disagree, but only loudly, never silently.
  const stillOpen = records.filter((r) => r.closeout_note);
  if (stillOpen.length > 0) {
    lines.push("## Still open on GitHub");
    lines.push("");
    lines.push(
      "These lanes are marked done, but the daemon could not confirm GitHub agrees. Check by hand."
    );
    lines.push("");
    for (const r of stillOpen) {
      lines.push(`- ${issueLink(r.issue)} (${prLink(r.pr)}): ${r.closeout_note}`);
    }
    lines.push("");
  }
  lines.push("## Needs Ben");
  lines.push("");
  const blocked = records.filter((r) => r.status === "blocked");
  if (blocked.length === 0) {
    lines.push("Nothing right now.");
  } else {
    for (const r of blocked) {
      lines.push(`- ${issueLink(r.issue)}: ${r.blocked_reason ?? "no reason recorded"}`);
    }
  }
  lines.push("");
  lines.push("## Deputy rulings");
  lines.push("");
  const rulings = readLogLines().filter(
    (l) => typeof l.msg === "string" && l.msg.startsWith("DEPUTY")
  );
  if (rulings.length === 0) {
    lines.push("None.");
  } else {
    for (const l of rulings) {
      lines.push(`- ${l.ts} ${issueLink(l.issue)}: ${l.msg}`);
    }
  }
  lines.push("");
  // Parked or abandoned lanes leave their branch and open pull request
  // behind on purpose -- closing them is a human judgment call, not the
  // daemon's -- so the board makes them impossible to miss instead.
  lines.push("## Left behind");
  lines.push("");
  const leftBehind = records.filter((r) => r.status === "blocked" && (r.branch || r.pr));
  if (leftBehind.length === 0) {
    lines.push("Nothing right now.");
  } else {
    for (const r of leftBehind) {
      lines.push(
        `- ${issueLink(r.issue)}: branch ${r.branch ?? "-"}, pull request ${prLink(r.pr)}`
      );
    }
  }
  lines.push("");
  writeFileAtomic(path.join(stateDir(), "board.md"), lines.join("\n"));
  process.stdout.write(`wrote ${path.join(stateDir(), "board.md")}\n`);
}

// Like readLogLines, but includes the rotated file (log.jsonl.1) first so
// stats can look back past a rotation. Order is oldest lines first.
function readLogLinesWithRotated() {
  const current = logPath();
  const lines = [];
  for (const file of [`${current}.1`, current]) {
    if (!fs.existsSync(file)) continue;
    for (const raw of fs.readFileSync(file, "utf8").split("\n")) {
      if (raw.trim() === "") continue;
      try {
        lines.push(JSON.parse(raw));
      } catch {
        // skip malformed lines, same as readLogLines
      }
    }
  }
  return lines;
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// Monday (UTC) of the week the timestamp falls in, as YYYY-MM-DD -- the
// label each stats row is grouped under.
function weekOf(ms) {
  const d = new Date(ms);
  const daysSinceMonday = (d.getUTCDay() + 6) % 7;
  const monday = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - daysSinceMonday));
  return monday.toISOString().slice(0, 10);
}

// fleetctl stats [--days N]: a read-only report on the fleet's own output.
// Everything comes from the log (when a lane was added, finished, or parked)
// and the task records (fix-round and relay counters); nothing is written.
function cmdStats(argv) {
  let days = 30;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--days") {
      const raw = argv[++i];
      if (!raw || !/^\d+$/.test(raw) || Number(raw) === 0) {
        throw usageError(`--days needs a positive whole number, got "${raw ?? ""}"`);
      }
      days = Number(raw);
    } else {
      throw usageError(`stats only takes --days N; got "${argv[i]}"`);
    }
  }
  const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;

  // First "added", first "status=done", and first "status=blocked" timestamp
  // per lane, from the log (records carry no creation time of their own).
  const addedAt = new Map();
  const doneAt = new Map();
  const parkEvents = []; // { issue, ms } for every park, first per lane kept below
  for (const line of readLogLinesWithRotated()) {
    if (typeof line.issue !== "number" || typeof line.msg !== "string") continue;
    const ms = Date.parse(line.ts ?? "");
    if (Number.isNaN(ms)) continue;
    if (line.msg.startsWith("added:") && !addedAt.has(line.issue)) {
      addedAt.set(line.issue, ms);
    } else if (/(^|\s)status=done(\s|$)/.test(line.msg) && !doneAt.has(line.issue)) {
      doneAt.set(line.issue, ms);
    } else if (/(^|\s)status=blocked(\s|$)/.test(line.msg)) {
      parkEvents.push({ issue: line.issue, ms });
    }
  }
  const parkedAt = new Map(); // first park per lane
  for (const p of parkEvents) {
    if (!parkedAt.has(p.issue)) parkedAt.set(p.issue, p.ms);
  }

  const recordByIssue = new Map(readAllRecords().map((r) => [r.issue, r]));
  const fixRoundsOf = (r) =>
    (r?.ci_fix_rounds ?? 0) + (r?.qa_fix_rounds ?? 0) + (r?.merge_fix_rounds ?? 0);

  // Group finished and parked lanes into weeks inside the window.
  const weeks = new Map(); // label -> { finished: [issue], parked: [issue] }
  const weekBucket = (label) => {
    if (!weeks.has(label)) weeks.set(label, { finished: [], parked: [] });
    return weeks.get(label);
  };
  for (const [issue, ms] of doneAt) {
    if (ms >= cutoff) weekBucket(weekOf(ms)).finished.push(issue);
  }
  for (const [issue, ms] of parkedAt) {
    if (ms >= cutoff) weekBucket(weekOf(ms)).parked.push(issue);
  }

  const out = [];
  out.push(`Fleet stats, last ${days} days.`);
  out.push("");
  const allLeadHours = [];
  let totalFinished = 0;
  let totalParked = 0;
  for (const label of [...weeks.keys()].sort()) {
    const { finished, parked } = weeks.get(label);
    totalFinished += finished.length;
    totalParked += parked.length;
    const leadHours = finished
      .filter((i) => addedAt.has(i))
      .map((i) => (doneAt.get(i) - addedAt.get(i)) / (60 * 60 * 1000));
    allLeadHours.push(...leadHours);
    const medLead = median(leadHours);
    const mean = (xs) =>
      xs.length === 0 ? null : xs.reduce((a, b) => a + b, 0) / xs.length;
    const fixMean = mean(finished.map((i) => fixRoundsOf(recordByIssue.get(i))));
    const relayMean = mean(finished.map((i) => recordByIssue.get(i)?.relays ?? 0));
    out.push(`Week of ${label}`);
    out.push(`  Lanes finished: ${finished.length}`);
    out.push(
      `  Lead time, median: ${medLead === null ? "unknown (no start time in the log)" : `${medLead.toFixed(1)} hours from added to done`}`
    );
    out.push(`  Fix rounds per finished lane: ${fixMean === null ? "-" : fixMean.toFixed(1)}`);
    out.push(`  Relays per finished lane: ${relayMean === null ? "-" : relayMean.toFixed(1)}`);
    out.push(`  Lanes parked for Ben: ${parked.length}`);
    out.push("");
  }
  if (weeks.size === 0) {
    out.push("Nothing finished or parked in this window.");
    out.push("");
  }
  const totalMed = median(allLeadHours);
  out.push(
    `Whole window: ${totalFinished} finished, ` +
      `median lead time ${totalMed === null ? "unknown" : `${totalMed.toFixed(1)} hours`}, ` +
      `${totalParked} parked for Ben.`
  );
  process.stdout.write(`${out.join("\n")}\n`);
}

const USAGE = `usage:
  fleetctl add <issue> spec=<path> tier=<routine|sensitive|security>
  fleetctl set <issue> field=value ...   (relays=+1 and qa_rounds=+1 increment)
  fleetctl get <issue>
  fleetctl list
  fleetctl board
  fleetctl log <issue> <message>
  fleetctl rotate-log                    (forces the same rotation the 10 MB cap does)
  fleetctl stats [--days N]              (read-only report: finished, lead time, fix rounds, relays, parks; default 30 days)
`;

function main() {
  const [command, ...rest] = process.argv.slice(2);
  try {
    switch (command) {
      case "add":
        cmdAdd(rest);
        break;
      case "set":
        cmdSet(rest);
        break;
      case "get":
        cmdGet(rest);
        break;
      case "list":
        cmdList();
        break;
      case "board":
        cmdBoard();
        break;
      case "log":
        cmdLog(rest);
        break;
      case "rotate-log":
        forceRotateLog();
        break;
      case "stats":
        cmdStats(rest);
        break;
      default:
        process.stderr.write(USAGE);
        process.exit(2);
    }
  } catch (err) {
    if (err instanceof CliError) {
      process.stderr.write(`fleetctl: ${err.message}\n`);
      process.exit(err.exitCode);
    }
    throw err;
  }
}

main();
