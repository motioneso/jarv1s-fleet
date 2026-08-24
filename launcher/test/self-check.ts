import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  addLabelArgs,
  boardListArgs,
  createLabelArgs,
  issueRowText,
  parseBoardItems,
  removeLabelArgs,
  setRunLabel
} from "../src/issues.js";
import { launchArgs, serviceFiles, stopTimerCommands } from "../src/operations.js";
import { cloneDefaults, parseBuildAnswers, rememberRepo, repoLooksReal } from "../src/setup.js";
import {
  clearTokenCounts,
  fleetAlarms,
  loadState,
  spawnWindowStart,
  spawnsSince,
  spawnsTonight
} from "../src/state.js";
import { fleetTokenUsage, isClaudeLane, laneTokenUsage } from "../src/tokens.js";
import type { Settings } from "../src/types.js";
import { listWindow, progressTrack, story, tabLanes } from "../src/view.js";

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
  assert.equal(spawnsTonight(dir, state.logs, spawnNow), 7);
  // A counter left over from an earlier night is not tonight's count.
  fs.writeFileSync(counterFile, `${windowSeconds - 86400} 7\n`);
  assert.equal(spawnsTonight(dir, state.logs, spawnNow), 0);
  // A garbled counter falls back to counting the log.
  fs.writeFileSync(counterFile, "not a counter\n");
  assert.equal(spawnsTonight(dir, state.logs, spawnNow), 1);
  // No counter file at all falls back to counting the log too.
  fs.rmSync(counterFile);
  assert.equal(spawnsTonight(dir, state.logs, spawnNow), 1);
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

// Session files live under a folder named after the lane's worktree path,
// the same way the Claude program's own on-disk layout does.
const worktree = path.join(fakeHome, "lane-9-worktree");
const projectDir = path.join(fakeHome, ".claude", "projects", worktree.replace(/[/.]/g, "-"));
fs.mkdirSync(projectDir, { recursive: true });
const sessionOne = path.join(projectDir, "session-one.jsonl");
fs.writeFileSync(sessionOne, usageLine(100, 20, 5000));

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
fs.writeFileSync(sessionTwo, usageLine(200, 40, 500));
const thirdRead = laneTokenUsage(fakeHome, tokenLane, fakeHome);
assert.equal(thirdRead.usage.input, 350);
assert.equal(thirdRead.usage.output, 70);
assert.equal(thirdRead.usage.cacheRead, 6500);
assert.equal(thirdRead.sessionCount, 2);

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

// A board answer shaped exactly like what `gh project item-list --format json`
// returned in a real read-only call on 2026-08-24: items carry `labels` as a
// plain string array, `status` is the column name, and the repository is
// sometimes "owner/name" and sometimes a full URL.
const boardJson = JSON.stringify({
  items: [
    {
      content: { type: "Issue", number: 11, title: "Fix the thing", repository: "motioneso/moss" },
      labels: ["task", "fleet-run"],
      status: "Ready"
    },
    {
      content: {
        type: "Issue",
        number: 12,
        title: "Another thing",
        repository: "https://github.com/motioneso/moss"
      },
      labels: ["task"],
      status: "In progress"
    },
    {
      content: { type: "Issue", number: 13, title: "Finished", repository: "motioneso/moss" },
      labels: ["task", "fleet-run"],
      status: "Done"
    },
    {
      content: { type: "Issue", number: 14, title: "Not task work", repository: "motioneso/moss" },
      labels: ["bug"],
      status: "Ready"
    },
    { content: { type: "DraftIssue", title: "Just a draft" }, labels: ["task"], status: "Ready" }
  ]
});
const pickerRows = parseBoardItems(boardJson);
// Every real issue in Ready or In Progress makes the list, whatever its
// labels -- the run is opt-in by hand, so the chooser must match what the
// board's columns show. Done issues and drafts do not.
assert.deepEqual(
  pickerRows.map((row) => row.number),
  [11, 12, 14]
);
// A repository given as a full URL is trimmed to owner/name for the label commands.
assert.equal(pickerRows[1]?.repo, "motioneso/moss");
// A labeled issue renders with the plain-English mark, an unlabeled one without it.
assert.equal(pickerRows[0]?.inRun, true);
assert.equal(pickerRows[1]?.inRun, false);
assert.ok(issueRowText(pickerRows[0]!, 80).includes("in this run"));
assert.ok(!issueRowText(pickerRows[1]!, 80).includes("in this run"));
assert.ok(issueRowText(pickerRows[0]!, 80).startsWith("#11 "));
assert.ok(issueRowText(pickerRows[0]!, 80).includes("Ready"));
// A long title is cut so the line still fits the terminal.
assert.ok(issueRowText({ ...pickerRows[1]!, title: "x".repeat(300) }, 60).length <= 60);

// The picker asks the same board the daemon reads: the two environment
// variables when set, otherwise project 2 owned by the signed-in user.
assert.deepEqual(boardListArgs({}), [
  "project",
  "item-list",
  "2",
  "--owner",
  "@me",
  "--format",
  "json",
  "--limit",
  "1000"
]);
assert.deepEqual(
  boardListArgs({ FLEET_PROJECT_NUMBER: "7", FLEET_PROJECT_OWNER: "someone" }).slice(2, 5),
  ["7", "--owner", "someone"]
);

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
