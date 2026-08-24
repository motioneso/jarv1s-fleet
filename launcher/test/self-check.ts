import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { launchArgs, serviceFiles, stopTimerCommands } from "../src/operations.js";
import { cloneDefaults, parseBuildAnswers } from "../src/setup.js";
import { loadState, spawnsSince } from "../src/state.js";
import { fleetTokenUsage, isClaudeLane, laneTokenUsage } from "../src/tokens.js";
import type { Settings } from "../src/types.js";
import { story, tabLanes } from "../src/view.js";

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

console.log("fleet launcher self-check passed");
