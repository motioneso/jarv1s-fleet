import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import React from "react";
import { Box, render } from "ink";
import {
  addLabelArgs,
  createLabelArgs,
  issueRowText,
  removeLabelArgs,
  setRunLabel
} from "../src/issues.js";
import {
  composeReplyBody,
  launchArgs,
  promptAgentArgs,
  repliesDir,
  serviceFiles,
  stopTimerCommands,
  writeReplyFile
} from "../src/operations.js";
import { cloneDefaults, parseBuildAnswers, rememberRepo, repoLooksReal } from "../src/setup.js";
import {
  clearTokenCounts,
  fleetAlarms,
  loadState,
  markBoardIssue,
  spawnWindowStart,
  spawnsSince,
  spawnsInWindow
} from "../src/state.js";
import { fleetTokenUsage, isClaudeLane, isLaneSession, laneTokenUsage } from "../src/tokens.js";
import type { Settings } from "../src/types.js";
import {
  ActionStrip,
  composeRow,
  displayWidth,
  exitSummary,
  issueUrlBase,
  KEY_MAPS,
  laneActions,
  laneModelLabel,
  listWindow,
  progressTrack,
  story,
  tabLanes,
  Viewer,
  isWaitingOnHuman,
  waitingOnIssues
} from "../src/view.js";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-launcher-"));
fs.mkdirSync(path.join(dir, "tasks"));
fs.writeFileSync(path.join(dir, "run-started"), "2026-08-23T00:00:00.000Z\n");
fs.writeFileSync(
  path.join(dir, "tasks", "1.json"),
  JSON.stringify({ issue: 1, status: "done", updated_at: "2026-08-23T01:00:00.000Z" })
);
fs.writeFileSync(path.join(dir, "tasks", "2.json"), "not json");
fs.writeFileSync(
  path.join(dir, "log.jsonl"),
  '{"ts":"2026-08-24T02:00:00.000Z","issue":1,"msg":"spawn: one"}\n'
);

const state = loadState(dir);
assert.equal(state.lanes.length, 1);
assert.equal(state.errors.length, 1);
assert.equal(spawnsSince(state.logs, new Date("2026-08-24T03:00:00.000Z")), 1);

// The Ready tab reads the daemon board snapshot from disk. A junk row
// without an issue number is dropped rather than crashing the screen.
fs.writeFileSync(
  path.join(dir, "board-issues.json"),
  JSON.stringify([
    { number: 41, title: "A", column: "Ready", inRun: true, repo: "o/r" },
    { title: "no number", column: "Ready" },
    { number: 42, title: "B", column: "In progress", inRun: false, repo: "o/r" }
  ])
);
{
  const withBoard = loadState(dir);
  assert.equal(withBoard.boardIssues.length, 2);
  assert.equal(withBoard.boardIssues[0]?.number, 41);
  assert.equal(withBoard.boardIssues[0]?.inRun, true);
}

// The header's agent-start count comes from the daemon's counter file, which
// survives the event log's 10 MB rotation; counting log lines is only the
// fallback when no counter exists yet.
{
  const spawnNow = new Date("2026-08-24T03:00:00.000Z");
  const windowSeconds = spawnWindowStart(spawnNow) / 1000;
  const counterFile = path.join(dir, ".spawn-count");
  fs.writeFileSync(counterFile, `${windowSeconds} 7\n`);
  assert.equal(spawnsInWindow(dir, state.logs, spawnNow), 7);
  // A counter left over from an earlier budget window does not count.
  fs.writeFileSync(counterFile, `${windowSeconds - 86400} 7\n`);
  assert.equal(spawnsInWindow(dir, state.logs, spawnNow), 0);
  // A garbled counter falls back to counting the log.
  fs.writeFileSync(counterFile, "not a counter\n");
  assert.equal(spawnsInWindow(dir, state.logs, spawnNow), 1);
  // No counter file at all falls back to counting the log too.
  fs.rmSync(counterFile);
  assert.equal(spawnsInWindow(dir, state.logs, spawnNow), 1);
}

// Starting a run must zero the "Tokens this run" totals -- without deleting
// the counter files. Each one remembers how far into every transcript the
// counter has read; losing that re-reads whole old transcripts and books
// their history to the new run. Zeroing keeps the file, zeroes the totals,
// and fast-forwards the read position to the transcript's current end.
{
  const usageDir = path.join(dir, "token-usage");
  fs.mkdirSync(usageDir, { recursive: true });
  const transcript = path.join(dir, "old-transcript.jsonl");
  fs.writeFileSync(transcript, "history line\n");
  fs.writeFileSync(
    path.join(usageDir, "1.json"),
    JSON.stringify({
      sessions: { [transcript]: { offset: 3, usage: { input: 9, output: 9, cacheRead: 9 } } }
    })
  );
  fs.writeFileSync(path.join(usageDir, "2.json"), "not json");
  clearTokenCounts(dir);
  const cleared = JSON.parse(fs.readFileSync(path.join(usageDir, "1.json"), "utf8"));
  assert.deepEqual(cleared.sessions[transcript].usage, { input: 0, output: 0, cacheRead: 0 });
  assert.equal(cleared.sessions[transcript].offset, fs.statSync(transcript).size);
  // A garbled counter file has no totals worth keeping and is dropped.
  assert.equal(fs.existsSync(path.join(usageDir, "2.json")), false);
  // Zeroing a state folder with no totals yet is not an error.
  fs.rmSync(usageDir, { recursive: true, force: true });
  clearTokenCounts(dir);
}

// The screen shows each distinct alarm once (its newest firing), not one
// line per tick it fired: a stuck condition repeats every minute and would
// flood the screen.
{
  const alarmNow = new Date("2026-08-24T12:00:00.000Z");
  const alarms = fleetAlarms(
    [
      { ts: "2026-08-24T11:50:00.000Z", issue: "fleet", msg: "ALARM: same thing" },
      { ts: "2026-08-24T11:55:00.000Z", issue: "fleet", msg: "ALARM: same thing" },
      { ts: "2026-08-24T11:56:00.000Z", issue: "fleet", msg: "ALARM: another thing" },
      { ts: "2026-08-24T09:00:00.000Z", issue: "fleet", msg: "ALARM: too old" }
    ],
    alarmNow
  );
  assert.equal(alarms.length, 2);
  assert.equal(alarms[0]?.ts, "2026-08-24T11:55:00.000Z");
  assert.equal(alarms[1]?.msg, "ALARM: another thing");
}

// An alarm the daemon can recover from stops being shown as soon as the
// matching all-clear is logged, and comes back if it fails again afterwards.
{
  const alarmNow = new Date("2026-08-24T12:00:00.000Z");
  const starving = {
    ts: "2026-08-24T11:30:00.000Z",
    issue: "fleet" as const,
    msg: "ALARM: GitHub is refusing to answer (its hourly allowance is exhausted); skipping"
  };
  const allClear = {
    ts: "2026-08-24T11:45:00.000Z",
    issue: "fleet" as const,
    msg: "GitHub is answering again; the allowance has reset"
  };
  // Nothing has cleared it, so it is still on screen.
  assert.equal(fleetAlarms([starving], alarmNow).length, 1);
  // The all-clear came later, so the fault is over and the line goes away.
  assert.deepEqual(fleetAlarms([starving, allClear], alarmNow), []);
  // A fresh failure after the recovery is a new fault and is shown again.
  const again = { ...starving, ts: "2026-08-24T11:50:00.000Z" };
  const afterRecovery = fleetAlarms([starving, allClear, again], alarmNow);
  assert.equal(afterRecovery.length, 1);
  assert.equal(afterRecovery[0]?.ts, "2026-08-24T11:50:00.000Z");
  // An all-clear cancels only its own alarm, never an unrelated one.
  const other = { ts: "2026-08-24T11:31:00.000Z", issue: "fleet" as const, msg: "ALARM: judge broke" };
  assert.deepEqual(fleetAlarms([starving, other, allClear], alarmNow), [other]);
}

// Switching projects keeps a remembered list: the new folder becomes both the
// active one and the head of the list, earlier folders stay pickable, nothing
// appears twice, and the list never grows past ten entries.
{
  const base = { ...cloneDefaults(), repo: "/old", repoHistory: ["/old", "/older"] };
  const switched = rememberRepo(base, "/new");
  assert.equal(switched.repo, "/new");
  assert.deepEqual(switched.repoHistory, ["/new", "/old", "/older"]);
  // Switching back to a known folder reorders; it does not duplicate.
  const back = rememberRepo(switched, "/older");
  assert.deepEqual(back.repoHistory, ["/older", "/new", "/old"]);
  // Settings from before the history existed still work: the active repo
  // seeds the list.
  const legacy = rememberRepo({ ...cloneDefaults(), repo: "/only" }, "/fresh");
  assert.deepEqual(legacy.repoHistory, ["/fresh", "/only"]);
  const many = Array.from({ length: 12 }, (_, index) => `/repo-${index}`);
  let grown = { ...cloneDefaults(), repo: "" };
  for (const entry of many) grown = rememberRepo(grown, entry);
  assert.equal(grown.repoHistory?.length, 10);
  assert.equal(grown.repoHistory?.[0], "/repo-11");
}

// Long lists show at most ten rows, in a window that follows the selection:
// pinned to the top at the start, centred in the middle, pinned to the
// bottom at the end, and never wider than the list itself.
{
  assert.deepEqual(listWindow(199, 0), { start: 0, end: 10 });
  assert.deepEqual(listWindow(199, 150), { start: 145, end: 155 });
  assert.deepEqual(listWindow(199, 198), { start: 189, end: 199 });
  assert.deepEqual(listWindow(5, 2), { start: 0, end: 5 });
  assert.deepEqual(listWindow(0, 0), { start: 0, end: 0 });
}

// Line two of a lane block is a progress track: the whole pipeline in plain
// text with the lane's current stage bracketed, checks and review states
// collapsing onto their stage.
assert.equal(
  progressTrack({ issue: 1, status: "building" }),
  "queued > [build] > checks > review > merge > done"
);
assert.equal(
  progressTrack({ issue: 1, status: "qa-red" }),
  "queued > build > checks > [review] > merge > done"
);
assert.ok(progressTrack({ issue: 1, status: "ci-red" }).includes("[checks]"));
assert.ok(progressTrack({ issue: 1, status: "merging" }).includes("[merge]"));
// An unknown status draws the track with no stage claimed.
assert.ok(!progressTrack({ issue: 1, status: "mystery" }).includes("["));
assert.equal(cloneDefaults().deputyEnabled, false);
assert.equal(cloneDefaults().judgeCmd, "codex exec");
for (const build of Object.values(cloneDefaults().buildModels)) assert.equal(build.tool, "codex");
assert.equal(parseBuildAnswers("a/low, b/high, c/medium").buildModels.security.model, "c");
assert.equal(parseBuildAnswers("a/low, b/high, c/medium").buildModels.security.effort, "medium");
// A two-part answer keeps the program already set for that kind of work.
assert.equal(
  parseBuildAnswers("a/low").buildModels.routine.tool,
  cloneDefaults().buildModels.routine.tool
);
// A three-part answer sets the program as well.
const threePart = parseBuildAnswers("some-tool/some-model/low");
assert.equal(threePart.buildModels.routine.tool, "some-tool");
assert.equal(threePart.buildModels.routine.model, "some-model");
assert.equal(threePart.buildModels.routine.effort, "low");
// Every kind of work names the program that runs it.
for (const build of Object.values(cloneDefaults().buildModels)) assert.ok(build.tool);
// Each program gets the flags it actually understands.
assert.deepEqual(launchArgs("claude", "m", "high"), [
  "--model",
  "m",
  "--effort",
  "high",
  "--permission-mode",
  "bypassPermissions"
]);
assert.deepEqual(launchArgs("codex", "m", "high"), [
  "-m",
  "m",
  "-c",
  "model_reasoning_effort=high",
  "-s",
  "danger-full-access",
  "-a",
  "never"
]);
assert.deepEqual(launchArgs("something-else", "m", "high"), ["--model", "m"]);
assert.equal(tabLanes(state, "Completed This Run").length, 1);
const completed = state.lanes[0];
assert.ok(completed);
completed.updated_at = "2026-08-22T23:00:00.000Z";
assert.equal(tabLanes(state, "Completed This Run").length, 0);

// A finished lane shows how long the work took, not a clock still running from the moment
// it finished. Lane 1's first log entry is 02:00, so finishing at 02:45 took 45 minutes.
const finishedStory = story(
  { issue: 1, status: "done", updated_at: "2026-08-24T02:45:00.000Z" },
  state
);
assert.match(finishedStory, /Took: 45m/);
assert.ok(!finishedStory.includes("Working for"));
// A lane still going keeps its running clock.
assert.match(story({ issue: 1, status: "building" }, state), /Working for:/);
assert.match(
  story({ issue: 1, status: "blocked", blocked_reason: "spawn budget exhausted" }, state),
  /Status: parked/
);

const service = serviceFiles(dir, path.join(dir, "config"));
assert.match(service.serviceText, /Environment=JARV1S_FLEET_STATE=/);
// The daemon is told which product checkout to build in.
assert.match(service.serviceText, /Environment=JARV1S_REPO=/);
assert.match(service.timerText, /WantedBy=timers\.target/);

// The repo folder chosen in setup is what actually ends up in the service file,
// not just whatever JARV1S_REPO happens to be set to.
const chosen = serviceFiles(dir, path.join(dir, "config"), "/home/someone/chosen-checkout");
assert.match(chosen.serviceText, /Environment=JARV1S_REPO="\/home\/someone\/chosen-checkout"/);
assert.equal(cloneDefaults().repo, "");

// The lane watchdog installs as its own service unit, next to the tick one, so the
// two can be enabled independently.
assert.match(service.watchdogService, /jarv1s-fleet-watchdog\.service$/);
assert.match(service.watchdogTimer, /jarv1s-fleet-watchdog\.timer$/);
assert.match(service.watchdogServiceText, /Environment=JARV1S_FLEET_STATE=/);
assert.match(service.watchdogServiceText, /fleet-watchdog\.sh/);
assert.match(service.watchdogTimerText, /WantedBy=timers\.target/);

const sourceDir = path.resolve(import.meta.dirname, "../src");
const seed = fs.readFileSync(path.join(sourceDir, "setup.ts"), "utf8");
const modelNames = [...seed.matchAll(/model: "([^"]+)"/g)].map((match) => match[1]);
for (const file of fs
  .readdirSync(sourceDir)
  .filter((name) => /\.(ts|tsx)$/.test(name) && name !== "setup.ts")) {
  const source = fs.readFileSync(path.join(sourceDir, file), "utf8");
  for (const name of modelNames)
    assert.doesNotMatch(
      source,
      new RegExp(`\\b${name.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")}\\b`)
    );
}
// The Completed This Run section freezes at the moment the run was actually
// ended, rather than keep counting lanes that finished after that point.
{
  const withEnd = { ...state, runEnded: "2026-08-24T02:30:00.000Z" };
  const finishedBeforeEnd = { issue: 1, status: "done", updated_at: "2026-08-24T02:00:00.000Z" };
  const finishedAfterEnd = { issue: 2, status: "done", updated_at: "2026-08-24T03:00:00.000Z" };
  const frozen = { ...withEnd, lanes: [finishedBeforeEnd, finishedAfterEnd] };
  assert.equal(tabLanes(frozen, "Completed This Run").length, 1);
  assert.equal(tabLanes(frozen, "Completed This Run")[0]?.issue, 1);
}

// -- Token accounting -------------------------------------------------

const fakeHome = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-launcher-home-"));
const claudeTool: Settings = {
  ...cloneDefaults(),
  buildModels: {
    ...cloneDefaults().buildModels,
    routine: { tool: "claude", model: cloneDefaults().buildModels.routine.model, effort: "medium" }
  }
};
const otherTool: Settings = {
  ...cloneDefaults(),
  buildModels: {
    ...cloneDefaults().buildModels,
    routine: { tool: "some-other-program", model: "x", effort: "medium" }
  }
};

function usageLine(input: number, output: number, cacheRead: number): string {
  return (
    JSON.stringify({
      type: "assistant",
      message: {
        usage: {
          input_tokens: input,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: cacheRead,
          output_tokens: output
        }
      }
    }) + "\n"
  );
}

// The opening user message of a fleet-spawned session, which points the
// agent at the brief the fleet wrote for that lane. This is what marks a
// transcript as belonging to the lane rather than merely sharing its folder.
function briefOpening(briefName: string): string {
  return (
    JSON.stringify({
      type: "user",
      message: {
        role: "user",
        content: `You are a fleet lane agent. Read and follow the brief at ${path.join(
          fakeHome,
          "briefs",
          briefName
        )} exactly.`
      }
    }) + "\n"
  );
}

// Session files live under a folder named after the lane's worktree path,
// the same way the Claude program's own on-disk layout does.
const worktree = path.join(fakeHome, "lane-9-worktree");
const projectDir = path.join(fakeHome, ".claude", "projects", worktree.replace(/[/.]/g, "-"));
fs.mkdirSync(projectDir, { recursive: true });
const sessionOne = path.join(projectDir, "session-one.jsonl");
fs.writeFileSync(sessionOne, briefOpening("brief-9-build.md") + usageLine(100, 20, 5000));

const tokenLane = { issue: 9, tier: "routine" as const, worktree };

// Token totals parsed from a fixture transcript.
const firstRead = laneTokenUsage(fakeHome, tokenLane, fakeHome);
assert.equal(firstRead.usage.input, 100);
assert.equal(firstRead.usage.output, 20);
assert.equal(firstRead.usage.cacheRead, 5000);
assert.equal(firstRead.sessionCount, 1);

// Incremental reading: appending more lines and reading again only picks up
// the new bytes, not the whole file again.
fs.appendFileSync(sessionOne, usageLine(50, 10, 1000));
const secondRead = laneTokenUsage(fakeHome, tokenLane, fakeHome);
assert.equal(secondRead.usage.input, 150);
assert.equal(secondRead.usage.output, 30);
assert.equal(secondRead.usage.cacheRead, 6000);

// A second session file for the same lane (a relay, or a fix agent) is
// included in the total rather than replacing the first session's spend.
const sessionTwo = path.join(projectDir, "session-two.jsonl");
fs.writeFileSync(sessionTwo, briefOpening("brief-9-qa-r1.md") + usageLine(200, 40, 500));
const thirdRead = laneTokenUsage(fakeHome, tokenLane, fakeHome);
assert.equal(thirdRead.usage.input, 350);
assert.equal(thirdRead.usage.output, 70);
assert.equal(thirdRead.usage.cacheRead, 6500);
assert.equal(thirdRead.sessionCount, 2);

// A session that merely shares the lane's folder -- earlier hand-run work on
// the same issue, in the same checkout -- is not the fleet's spend and must
// not be counted.
const strayFile = path.join(projectDir, "session-stray.jsonl");
fs.writeFileSync(
  strayFile,
  JSON.stringify({
    type: "user",
    message: { role: "user", content: "Read the file /home/ben/Jarv1s/boot-9-notes.txt in full." }
  }) +
    "\n" +
    usageLine(999, 999, 999)
);
const withStray = laneTokenUsage(fakeHome, tokenLane, fakeHome);
assert.equal(withStray.usage.input, 350);
assert.equal(withStray.sessionCount, 2);

// The brief name must match on a whole issue number: a lane for issue 1
// must not adopt issue 9's transcripts just because "9" follows "brief-".
assert.equal(isLaneSession(sessionOne, 9), true);
assert.equal(isLaneSession(sessionOne, 1), false);
assert.equal(isLaneSession(strayFile, 9), false);

// The same trap at the length the real fleet hits it: issue 188 must not
// pick up issue 1883's briefs.
const shortIssueDir = path.join(fakeHome, "short-issue-project");
fs.mkdirSync(shortIssueDir, { recursive: true });
const longIssueSession = path.join(shortIssueDir, "session-1883.jsonl");
fs.writeFileSync(longIssueSession, briefOpening("brief-1883-build.md") + usageLine(7, 7, 7));
assert.equal(isLaneSession(longIssueSession, 1883), true);
assert.equal(isLaneSession(longIssueSession, 188), false);

// A sidecar written before this check existed holds sessions that were never
// the lane's. Reading it drops them, and the drop is written back to disk.
const pollutedIssue = 77;
const pollutedSidecar = path.join(fakeHome, "token-usage", `${pollutedIssue}.json`);
fs.mkdirSync(path.dirname(pollutedSidecar), { recursive: true });
const ownedFile = path.join(projectDir, "session-77-owned.jsonl");
fs.writeFileSync(ownedFile, briefOpening("brief-77-build.md") + usageLine(10, 2, 1));
fs.writeFileSync(
  pollutedSidecar,
  JSON.stringify({
    sessions: {
      [ownedFile]: { offset: 0, usage: { input: 0, output: 0, cacheRead: 0 } },
      [strayFile]: { offset: 0, usage: { input: 4000, output: 4000, cacheRead: 4000 } }
    }
  })
);
const cleaned = laneTokenUsage(fakeHome, { issue: pollutedIssue, tier: "routine" as const }, fakeHome);
assert.equal(cleaned.sessionCount, 1);
assert.equal(cleaned.usage.input, 10);
const rewritten = JSON.parse(fs.readFileSync(pollutedSidecar, "utf8"));
assert.deepEqual(Object.keys(rewritten.sessions), [ownedFile]);

// A lane whose tier is configured to run under some other program is a
// non-Claude lane: fleetTokenUsage must leave it out of the Claude total.
assert.equal(isClaudeLane(tokenLane, claudeTool), true);
assert.equal(isClaudeLane(tokenLane, otherTool), false);
const claudeTotal = fleetTokenUsage(fakeHome, [tokenLane], claudeTool, fakeHome);
assert.equal(claudeTotal.input, 350);
const otherTotal = fleetTokenUsage(fakeHome, [tokenLane], otherTool, fakeHome);
assert.equal(otherTotal.input, 0);
assert.equal(otherTotal.output, 0);
assert.equal(otherTotal.cacheRead, 0);

// End-run stops both timers, not just the tick one.
const timerCommands = stopTimerCommands();
assert.equal(timerCommands.length, 2);
assert.ok(timerCommands.some((argv) => argv.join(" ").includes("jarv1s-fleet-tick.timer")));
assert.ok(timerCommands.some((argv) => argv.join(" ").includes("jarv1s-fleet-watchdog.timer")));
for (const argv of timerCommands) {
  assert.ok(argv.includes("disable"));
  assert.ok(argv.includes("--now"));
}

// -- Issue picker ------------------------------------------------------

// The picker reads the daemon's board snapshot from disk (the loadState
// check above already proves that read); these rows stand in for it.
const pickerRows = [
  { number: 11, title: "Fix the thing", column: "Ready", inRun: true, repo: "motioneso/moss" },
  {
    number: 12,
    title: "Another thing",
    column: "In progress",
    inRun: false,
    repo: "motioneso/moss"
  }
];
// A labeled issue renders with the plain-English mark, an unlabeled one without it.
assert.ok(issueRowText(pickerRows[0]!, 80).includes("in this run"));
assert.ok(!issueRowText(pickerRows[1]!, 80).includes("in this run"));
assert.ok(issueRowText(pickerRows[0]!, 80).startsWith("#11 "));
assert.ok(issueRowText(pickerRows[0]!, 80).includes("Ready"));
// A long title is cut so the line still fits the terminal.
assert.ok(issueRowText({ ...pickerRows[1]!, title: "x".repeat(300) }, 60).length <= 60);

// After a label flip the picker writes the new mark into the daemon's
// snapshot, so the Ready tab does not snap back to a five-minute-old truth.
// The write must not touch the file's clock: the daemon uses that clock to
// space out its board reads.
{
  const before = fs.statSync(path.join(dir, "board-issues.json")).mtimeMs;
  markBoardIssue(dir, 42, true);
  const marked = loadState(dir);
  assert.equal(marked.boardIssues.find((row) => row.number === 42)?.inRun, true);
  const after = fs.statSync(path.join(dir, "board-issues.json")).mtimeMs;
  assert.ok(Math.abs(after - before) < 10);
  markBoardIssue(path.join(dir, "nowhere"), 42, true); // no snapshot: must not throw
}

// "+" sends the add-label command and flips the mark on success.
{
  const calls: string[][] = [];
  const okGh = async (args: string[]) => {
    calls.push(args);
    return "";
  };
  const result = await setRunLabel(pickerRows, 1, true, okGh);
  assert.equal(result.error, undefined);
  assert.equal(result.rows[1]?.inRun, true);
  assert.deepEqual(calls, [addLabelArgs("motioneso/moss", 12)]);
}

// When the repo does not have the label yet, the picker creates it
// (idempotently, with --force) and retries the add once.
{
  const calls: string[][] = [];
  let addFailed = false;
  const missingLabelGh = async (args: string[]) => {
    calls.push(args);
    if (!addFailed && args.includes("--add-label")) {
      addFailed = true;
      throw new Error("could not add label: 'fleet-run' not found");
    }
    return "";
  };
  const result = await setRunLabel(pickerRows, 1, true, missingLabelGh);
  assert.equal(result.error, undefined);
  assert.equal(result.rows[1]?.inRun, true);
  assert.deepEqual(calls, [
    addLabelArgs("motioneso/moss", 12),
    createLabelArgs("motioneso/moss"),
    addLabelArgs("motioneso/moss", 12)
  ]);
  assert.ok(createLabelArgs("motioneso/moss").includes("--force"));
}

// "-" sends the remove-label command and clears the mark on success.
{
  const calls: string[][] = [];
  const okGh = async (args: string[]) => {
    calls.push(args);
    return "";
  };
  const result = await setRunLabel(pickerRows, 0, false, okGh);
  assert.equal(result.error, undefined);
  assert.equal(result.rows[0]?.inRun, false);
  assert.deepEqual(calls, [removeLabelArgs("motioneso/moss", 11)]);
}

// "-" on an issue that is not in the run sends nothing at all, so GitHub
// never gets a chance to answer with an error.
{
  const calls: string[][] = [];
  const okGh = async (args: string[]) => {
    calls.push(args);
    return "";
  };
  const result = await setRunLabel(pickerRows, 1, false, okGh);
  assert.equal(calls.length, 0);
  assert.equal(result.rows[1]?.inRun, false);
}

// A failed toggle reports the error in plain text and leaves the mark alone.
{
  const brokenGh = async () => {
    throw new Error("no network");
  };
  const result = await setRunLabel(pickerRows, 1, true, brokenGh);
  assert.match(result.error ?? "", /no network/);
  assert.match(result.error ?? "", /#12/);
  assert.equal(result.rows[1]?.inRun, false);
}

console.log("fleet launcher self-check passed");

// An old settings file without a usable repo must be detected, never silently
// defaulted: the launcher shows the repo question instead.
{
  const real = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-repo-"));
  fs.mkdirSync(path.join(real, ".git"));
  assert.equal(repoLooksReal(real), true);
  const bare = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-repo-"));
  assert.equal(repoLooksReal(bare), false, "a folder without a git checkout is not a repo");
  assert.equal(repoLooksReal(path.join(bare, "missing")), false, "a missing folder is not a repo");
  assert.equal(repoLooksReal(""), false, "settings saved before the repo question have no repo");
}

// -- List row composition ----------------------------------------------
// A list row is left text, padding, right text. Whatever the inputs, the
// three pieces together must never be wider than the row's budget - one
// extra terminal cell and the terminal wraps the row onto a second line.
{
  const lefts = [
    "",
    "> #41  Make the nightly build stop deleting its own cache",
    "  #46  ✅ A title with a two-cell check mark that runs on and on and on and on",
    "  #47  \u{1F680} An emoji rocket plus 日本語 wide characters in one title",
    "  #44  Decide what happens to archived boards  waiting on you: needs a product decision and a lot more words to overflow any row"
  ];
  const rights = ["", "building", "review found problems", "done in 2h 14m"];
  for (const width of [20, 36, 40, 44, 84, 120]) {
    for (const left of lefts) {
      for (const right of rights) {
        const row = composeRow(left, right, width);
        const total = displayWidth(row.left) + row.pad + displayWidth(row.right);
        assert.ok(
          total <= width,
          `a composed row overflows: width ${width}, got ${total} cells (${JSON.stringify(row)})`
        );
        assert.equal(total, width, `the highlight bar must fill the row: width ${width}`);
      }
    }
  }
  // The two-cell characters really count as two cells.
  assert.equal(displayWidth("✅"), 2);
  assert.equal(displayWidth("日本"), 4);
  assert.equal(displayWidth("plain"), 5);
}

// -- Which issues a lane is waiting on --------------------------------
// The split target counts, every #NNNN in the block and deputy notes
// counts, duplicates collapse, the lane's own number never counts.
assert.deepEqual(waitingOnIssues({ issue: 10, resliced_to: 1982 }), [1982]);
assert.deepEqual(
  waitingOnIssues({
    issue: 10,
    blocked_reason: "waiting on #1968 and #1969",
    deputy_reason: "also blocked by #1970"
  }),
  [1968, 1969, 1970]
);
assert.deepEqual(
  waitingOnIssues({
    issue: 10,
    resliced_to: 1968,
    blocked_reason: "re-sliced into #1968; the rest went to #1969 and #1968"
  }),
  [1968, 1969]
);
assert.deepEqual(
  waitingOnIssues({ issue: 1959, blocked_reason: "conflicts with #1959 and #1960" }),
  [1960]
);
assert.deepEqual(waitingOnIssues({ issue: 10, blocked_reason: "needs a product decision" }), []);
assert.deepEqual(waitingOnIssues({ issue: 10 }), []);
assert.equal(
  isWaitingOnHuman({ issue: 10, status: "blocked", blocked_reason: "spawn budget exhausted" }),
  false
);
assert.equal(
  isWaitingOnHuman({ issue: 10, status: "blocked", question: "needs a product decision" }),
  true
);
assert.equal(
  isWaitingOnHuman({ issue: 10, status: "blocked", question: "needs a product decision", paused: true }),
  false
);
// The link base comes from the lane's own issue URL; anything else means
// no link, plain text only.
assert.equal(
  issueUrlBase("https://github.com/motioneso/moss/issues/1982"),
  "https://github.com/motioneso/moss/issues"
);
assert.equal(issueUrlBase("specs/1982.md"), null);
assert.equal(issueUrlBase(null), null);
assert.equal(issueUrlBase(undefined), null);

// -- Acting on lanes from the app --------------------------------------
// The daemon finds a reply by grepping its content for the whole token
// "issue N"; the body the app writes must carry exactly that grammar.
{
  const daemonTokenRe = (issue: number) => new RegExp(`issue[\\s]+${issue}([^0-9]|$)`);
  assert.match(composeReplyBody("resume", 44), daemonTokenRe(44));
  assert.match(composeReplyBody("merge", 1834), daemonTokenRe(1834));
  assert.equal(composeReplyBody("resume", 44), "resume for issue 44");
  // Whole-token: a reply for issue 44 must never read as one for issue 4.
  assert.doesNotMatch(composeReplyBody("resume", 44), daemonTokenRe(4));
  // A typed answer keeps its own words first (the daemon acts on the first
  // word), with the issue token appended; whitespace is flattened the same
  // way the daemon flattens it.
  assert.equal(
    composeReplyBody("  keep the \n share links ", 12),
    "keep the share links for issue 12"
  );
}

// The replies folder honors NEEDS_BEN_DIR (tests never touch the real
// one), and one write means one new uniquely named file, never an overwrite.
{
  const fakeBenDir = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-needs-ben-"));
  const env = { NEEDS_BEN_DIR: fakeBenDir } as NodeJS.ProcessEnv;
  assert.equal(repliesDir(env), path.join(fakeBenDir, "replies"));
  assert.equal(
    repliesDir({} as NodeJS.ProcessEnv),
    path.join(os.homedir(), ".needs-ben", "replies")
  );
  const first = writeReplyFile(44, composeReplyBody("resume", 44), env);
  const second = writeReplyFile(44, composeReplyBody("resume", 44), env);
  assert.notEqual(first, second);
  assert.equal(fs.readFileSync(first, "utf8"), "resume for issue 44\n");
  assert.equal(fs.readdirSync(path.join(fakeBenDir, "replies")).length, 2);
}

// Which actions apply where: reply actions only on a lane parked for a
// human (a split lane is finished, not parked), instructions only where an
// agent is actually working, nothing anywhere else.
{
  assert.deepEqual(laneActions({ issue: 1, status: "blocked" }), ["resume", "merge", "reply"]);
  assert.deepEqual(
    laneActions({ issue: 1, status: "blocked", blocked_reason: "re-sliced into #9" }),
    []
  );
  assert.deepEqual(laneActions({ issue: 1, status: "building", agent: "fleet-1" }), ["instruct"]);
  assert.deepEqual(laneActions({ issue: 1, status: "building" }), []);
  assert.deepEqual(laneActions({ issue: 1, status: "qa", agent: "fleet-1" }), ["instruct"]);
  assert.deepEqual(laneActions({ issue: 1, status: "merging", agent: "fleet-1" }), ["instruct"]);
  assert.deepEqual(laneActions({ issue: 1, status: "pr-open", agent: "fleet-1" }), []);
  assert.deepEqual(laneActions({ issue: 1, status: "done" }), []);
  assert.deepEqual(laneActions({ issue: 1, status: "queued" }), []);
}

// The model label: model plus effort when both are known, model alone when
// the effort is not, and nothing at all for a record that predates it -- an
// older record must never render the word "undefined".
assert.equal(
  laneModelLabel({ issue: 1, agent_model: "opus-5", agent_effort: "high" }),
  "opus-5 high"
);
assert.equal(laneModelLabel({ issue: 1, agent_model: "opus-5" }), "opus-5");
assert.equal(laneModelLabel({ issue: 1, agent_model: "opus-5", agent_effort: "  " }), "opus-5");
assert.equal(laneModelLabel({ issue: 1 }), "");
assert.equal(laneModelLabel({ issue: 1, agent_model: null, agent_effort: "high" }), "");

// No input mode binds the same key twice.
for (const [mode, keys] of Object.entries(KEY_MAPS))
  assert.equal(new Set(keys).size, keys.length, `duplicate key binding in the ${mode} mode`);

// The instruction command is spelled the one way herdr accepts.
assert.deepEqual(promptAgentArgs("fleet-1900", "run the tests again"), [
  "agent",
  "prompt",
  "fleet-1900",
  "run the tests again"
]);

// -- Full-screen render check -----------------------------------------
// The viewer owns the whole terminal now, so the main screen is rendered
// against fake terminals of two real sizes with realistic lane data. The
// frame must fill every row, keep the key hints on the bottom row, and
// never write a line wider than the terminal.

class FakeStdout extends EventEmitter {
  columns: number;
  rows: number;
  frames: string[] = [];
  isTTY = true;
  constructor(columns: number, rows: number) {
    super();
    this.columns = columns;
    this.rows = rows;
  }
  write(chunk: string): boolean {
    this.frames.push(String(chunk));
    return true;
  }
}

class FakeStdin extends EventEmitter {
  isTTY = true;
  setRawMode(): this {
    return this;
  }
  setEncoding(): this {
    return this;
  }
  resume(): this {
    return this;
  }
  pause(): this {
    return this;
  }
  ref(): this {
    return this;
  }
  unref(): this {
    return this;
  }
  read(): null {
    return null;
  }
}

function stripStyles(text: string): string {
  // Terminal escape sequences carry no visible width; drop them before
  // measuring lines. That includes clickable-link escapes (OSC 8).
  // eslint-disable-next-line no-control-regex
  return text
    .replace(/\u001B\]8;;[^\u0007\u001B]*(?:\u0007|\u001B\\)/g, "")
    .replace(/\u001B\[[0-9;?]*[A-Za-z]/g, "");
}

const screenDir = fs.mkdtempSync(path.join(os.tmpdir(), "fleet-screen-"));
fs.mkdirSync(path.join(screenDir, "tasks"));
const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60000).toISOString();
fs.writeFileSync(path.join(screenDir, "run-started"), `${minutesAgo(134)}\n`);
const screenSettings: Settings = { ...cloneDefaults(), repo: "/tmp/fleet-fake-repo" };
fs.writeFileSync(path.join(screenDir, "settings.json"), JSON.stringify(screenSettings));
const screenLanes = [
  {
    issue: 41,
    title: "Make the nightly build stop deleting its own cache",
    status: "building",
    spec: "https://github.com/o/r/issues/41",
    deputy_reason: "holding until #1968 and #1969 land",
    // This lane's record says which model is doing the work; lane 42 below
    // has no such field, standing in for records written before the daemon
    // recorded it.
    agent_model: "opus-5",
    agent_effort: "high",
    agent_tool: "claude",
    updated_at: minutesAgo(12)
  },
  {
    issue: 42,
    title: "Retry the flaky login check before failing the run",
    status: "pr-open",
    pr: 88,
    checks: [
      { name: "tests", state: "success" },
      { name: "lint", state: "pending" }
    ],
    updated_at: minutesAgo(30)
  },
  {
    issue: 43,
    title: "Stop the exporter from writing empty files",
    status: "ci-red",
    pr: 89,
    failedCheck: "integration tests",
    updated_at: minutesAgo(8)
  },
  {
    issue: 44,
    title: "Decide what happens to archived boards",
    status: "blocked",
    blocked_reason: "needs a product decision",
    question: "Should archived boards keep their share links working, or return a gone page?",
    questionAskedAt: minutesAgo(50),
    updated_at: minutesAgo(50)
  },
  { issue: 45, title: "Speed up the search index rebuild", status: "qa", updated_at: minutesAgo(4) },
  {
    // A two-cell check mark plus a long title: the row must still fit on one
    // line, and the long status label must stay whole beside it.
    issue: 46,
    title: "✅ Stop the exporter from writing empty files after the nightly cleanup pass runs",
    status: "qa-red",
    updated_at: minutesAgo(2)
  },
  {
    issue: 40,
    title: "Rename the export button so people can find it",
    status: "done",
    updated_at: minutesAgo(20)
  }
];
for (const lane of screenLanes)
  fs.writeFileSync(path.join(screenDir, "tasks", `${lane.issue}.json`), JSON.stringify(lane));
const screenLog = [
  { ts: minutesAgo(130), issue: 40, msg: "spawn: build agent started" },
  { ts: minutesAgo(60), issue: 40, msg: "merged and closed out" },
  { ts: minutesAgo(120), issue: 41, msg: "spawn: build agent started" },
  { ts: minutesAgo(12), issue: 41, msg: "still building, tests green so far" },
  { ts: minutesAgo(9), issue: 43, msg: "integration tests failed on the second retry" },
  { ts: minutesAgo(5), issue: "fleet", msg: "ALARM: the judge command has failed twice in a row" }
];
fs.writeFileSync(
  path.join(screenDir, "log.jsonl"),
  screenLog.map((entry) => JSON.stringify(entry)).join("\n") + "\n"
);
fs.writeFileSync(
  path.join(screenDir, "board-issues.json"),
  JSON.stringify([
    { number: 51, title: "Add a keyboard shortcut list", column: "Ready", inRun: true, repo: "o/r" },
    { number: 52, title: "Trim the onboarding email", column: "Ready", inRun: false, repo: "o/r" }
  ])
);

async function renderScreen(columnsCount: number, rowsCount: number): Promise<string> {
  const fakeOut = new FakeStdout(columnsCount, rowsCount);
  const fakeIn = new FakeStdin();
  const app = render(
    React.createElement(Viewer, {
      dir: screenDir,
      initialSettings: screenSettings,
      daemonRunning: true
    }),
    {
      // Not real process streams, but they walk and quack like them.
      stdout: fakeOut as unknown as NodeJS.WriteStream,
      stdin: fakeIn as unknown as NodeJS.ReadStream,
      exitOnCtrlC: false,
      patchConsole: false
    }
  );
  await new Promise((resolve) => setTimeout(resolve, 80));
  const frame =
    fakeOut.frames
      .map(stripStyles)
      .filter((chunk) => chunk.trim() !== "")
      .at(-1) ?? "";
  // With fake streams Ink's exit promise never settles, so unmount without
  // waiting on it; unmount alone clears the refresh and spinner timers.
  app.unmount();
  return frame.replace(/\n$/, "");
}

for (const [columnsCount, rowsCount] of [
  [200, 50],
  [90, 25]
] as const) {
  const frame = await renderScreen(columnsCount, rowsCount);
  const lines = frame.split("\n");
  assert.equal(
    lines.length,
    rowsCount,
    `the ${columnsCount}x${rowsCount} screen fills every row (got ${lines.length})`
  );
  for (const line of lines)
    assert.ok(
      line.length <= columnsCount,
      `a line overflows the ${columnsCount}-column terminal: ${line.length} characters`
    );
  assert.ok(frame.includes("Fleet"), "the app name is on screen");
  assert.ok(frame.includes("Lanes"), "the status chips are on screen");
  assert.ok(frame.includes("ALARM"), "the alarm line is on screen");
  // How long ago the fault happened, so a stale alarm cannot pass for a fresh
  // one. The screen's alarm was logged five minutes ago.
  assert.ok(
    frame.includes("5m ago"),
    `the alarm says how long ago it fired; got: ${JSON.stringify(
      lines.find((line) => line.includes("ALARM"))
    )}`
  );
  assert.ok(frame.includes("#41"), "the lane list is on screen");
  const bottom = lines[lines.length - 1] ?? "";
  assert.ok(
    bottom.includes("quit"),
    `the key hints sit on the bottom row; got: ${JSON.stringify(lines.slice(-4))}`
  );
}

// On the narrowest terminal the app still draws on, the alarm's age survives:
// only the message text may be cut short, and nothing spills past the edge.
{
  const tightFrame = await renderScreen(60, 20);
  assert.ok(tightFrame.includes("5m ago"), "the alarm's age survives a 60-column terminal");
  for (const line of tightFrame.split("\n"))
    assert.ok(line.length <= 60, `a line overflows the 60-column terminal: ${line.length}`);
}

// The wide screen shows the detail card beside the list; the narrow one
// falls back to a single column with no detail panel.
{
  const wideFrame = await renderScreen(200, 50);
  assert.ok(wideFrame.includes("Pipeline"), "the wide screen shows the detail card");
  assert.ok(wideFrame.includes("Recent log"), "the detail card includes the log tail");
  // The lane with the two-cell check mark in its title: its long status
  // label must sit whole on the row, not spill onto the next line. A split
  // label would put a newline inside the phrase, so includes() would fail.
  assert.ok(
    wideFrame.includes("review found problems"),
    "the long status label stays on one line"
  );
  // The selected lane (41) waits on two issues; the detail card must name
  // them on a Waiting on line. The width checks above already proved no
  // rendered line overflows the terminal once the invisible link escapes
  // are stripped.
  // Lane 41 records its model, so the screen says which model is running it.
  // Lane 42 records none, and no row may show the word "undefined".
  assert.ok(wideFrame.includes("opus-5 high"), "the screen names the model running the lane");
  assert.ok(wideFrame.includes("Model"), "the detail card has a model line");
  assert.ok(!wideFrame.includes("undefined"), "a lane with no recorded model shows nothing");
  assert.ok(wideFrame.includes("Waiting on"), "the detail card shows the waiting-on line");
  assert.ok(
    wideFrame.includes("#1968") && wideFrame.includes("#1969"),
    "the waiting-on line names both issues"
  );
}

// Each In Progress entry is exactly three lines, even on a narrow screen:
// the issue row, one truncated descriptor line under it, then a blank line
// before the next issue (Ben's styling call, 2026-08-25).
{
  const narrowFrame = await renderScreen(90, 25);
  const lines = narrowFrame.split("\n");
  const stripBorder = (line?: string) => (line ?? "").replace(/[│╭╮╰╯─]/g, "").trim();
  const rowIndex = lines.findIndex((line) => line.includes("#41"));
  assert.ok(rowIndex >= 0, "the first lane's issue row is on screen");
  assert.ok(
    (lines[rowIndex + 1] ?? "").includes("Building for"),
    "the descriptor is the single line right under its issue"
  );
  assert.equal(stripBorder(lines[rowIndex + 2]), "", "a blank line separates the entries");
  assert.ok((lines[rowIndex + 3] ?? "").includes("#42"), "the next issue follows the blank line");
  // A held lane follows the same shape: its reason is the descriptor line.
  const heldIndex = lines.findIndex((line) => line.includes("#44"));
  assert.ok(heldIndex >= 0, "the held lane's issue row is on screen");
  assert.ok(
    (lines[heldIndex + 1] ?? "").includes("Waiting on you"),
    "the held lane's reason is its single descriptor line"
  );
  assert.equal(stripBorder(lines[heldIndex + 2]), "", "a blank line follows the held lane too");
}

// The action strip for a held lane: with a question outstanding the third
// option reads "answer", and every line stays inside the panel width.
{
  const stripWidth = 44;
  const fakeOut = new FakeStdout(stripWidth, 8);
  const app = render(
    React.createElement(
      Box,
      { width: stripWidth, flexDirection: "column" },
      React.createElement(ActionStrip, {
        strip: {
          mode: "menu",
          lane: {
            issue: 44,
            status: "blocked",
            question: "Should archived boards keep their share links working?"
          }
        },
        width: stripWidth
      })
    ),
    {
      stdout: fakeOut as unknown as NodeJS.WriteStream,
      stdin: new FakeStdin() as unknown as NodeJS.ReadStream,
      exitOnCtrlC: false,
      patchConsole: false
    }
  );
  await new Promise((resolve) => setTimeout(resolve, 40));
  const frame =
    fakeOut.frames
      .map(stripStyles)
      .filter((chunk) => chunk.trim() !== "")
      .at(-1) ?? "";
  app.unmount();
  assert.ok(frame.includes("resume"), "the strip offers resume");
  assert.ok(frame.includes("merge"), "the strip offers merge");
  assert.ok(
    frame.includes("answer") && !frame.includes("custom reply"),
    "with a question outstanding the third option reads answer"
  );
  for (const line of frame.split("\n"))
    assert.ok(
      line.length <= stripWidth,
      `an action strip line overflows ${stripWidth} cells: ${JSON.stringify(line)}`
    );
}

// The plain-text summary printed into the scrollback on quit.
{
  const summary = exitSummary(loadState(screenDir));
  assert.match(summary, /Fleet closed\. The run has been going for /);
  assert.match(summary, /Finished this run: 1 lane \(#40\)\./);
  assert.match(summary, /Waiting on you: #44 /);
  // It outlives the app in the scrollback, so it stays plain ASCII.
  assert.ok(!/[^\n\x20-\x7E]/.test(summary), "the exit summary is plain ASCII");
}

console.log("fleet launcher render check passed");
process.exit(0);
