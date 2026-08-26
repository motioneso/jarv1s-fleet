import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const CLI = resolve(__dirname, "../fleetctl.mjs");

let stateDir: string;

function run(args: string[]): { stdout: string; code: number } {
  try {
    const stdout = execFileSync(process.execPath, [CLI, ...args], {
      env: { ...process.env, JARV1S_FLEET_STATE: stateDir },
      encoding: "utf8"
    });
    return { stdout, code: 0 };
  } catch (err) {
    const e = err as { status?: number; stdout?: string };
    return { stdout: e.stdout ?? "", code: e.status ?? -1 };
  }
}

beforeEach(() => {
  stateDir = mkdtempSync(join(tmpdir(), "fleetctl-test-"));
});

afterEach(() => {
  rmSync(stateDir, { recursive: true, force: true });
});

describe("fleetctl", () => {
  it("round-trips a record through add and get", () => {
    const added = run(["add", "42", "spec=docs/specs/x.md", "tier=routine"]);
    expect(added.code).toBe(0);

    const got = run(["get", "42"]);
    expect(got.code).toBe(0);
    const record = JSON.parse(got.stdout);
    expect(record).toMatchObject({
      issue: 42,
      spec: "docs/specs/x.md",
      tier: "routine",
      status: "queued",
      pr: null,
      branch: null,
      worktree: null,
      agent: null,
      relays: 0,
      qa_rounds: 0,
      blocked_reason: null
    });
    expect(typeof record.updated_at).toBe("string");
  });

  it("exits 2 for get on a missing record", () => {
    expect(run(["get", "999"]).code).toBe(2);
  });

  it("sets fields and supports +1 increment syntax", () => {
    run(["add", "7", "spec=s.md", "tier=sensitive"]);
    const set = run(["set", "7", "status=pr-open", "pr=1234", "relays=+1", "qa_rounds=+1"]);
    expect(set.code).toBe(0);

    const record = JSON.parse(run(["get", "7"]).stdout);
    expect(record.status).toBe("pr-open");
    expect(record.pr).toBe(1234);
    expect(record.relays).toBe(1);
    expect(record.qa_rounds).toBe(1);

    run(["set", "7", "relays=+1"]);
    expect(JSON.parse(run(["get", "7"]).stdout).relays).toBe(2);
  });

  it("rejects a status outside the allowed vocabulary", () => {
    run(["add", "8", "spec=s.md", "tier=routine"]);
    expect(run(["set", "8", "status=finished"]).code).toBe(1);
    // record is unchanged
    expect(JSON.parse(run(["get", "8"]).stdout).status).toBe("queued");
  });

  it("rejects unknown fields", () => {
    run(["add", "9", "spec=s.md", "tier=routine"]);
    expect(run(["set", "9", "color=blue"]).code).toBe(1);
  });

  it("accepts teardown_attempts so the daemon's teardown retry cap can be recorded", () => {
    run(["add", "12", "spec=s.md", "tier=routine"]);
    expect(run(["set", "12", "teardown_attempts=2"]).code).toBe(0);
    expect(JSON.parse(run(["get", "12"]).stdout).teardown_attempts).toBe(2);
  });

  it("accepts reslice_failures so transient re-slice failures can be counted", () => {
    run(["add", "14", "spec=docs/a.md", "tier=routine"]);
    expect(run(["set", "14", "reslice_failures=2"]).code).toBe(0);
    expect(JSON.parse(run(["get", "14"]).stdout).reslice_failures).toBe(2);
  });

  it("accepts reslice_attempted so a parked lane's one re-slice try can be stamped", () => {
    run(["add", "13", "spec=s.md", "tier=routine"]);
    expect(run(["set", "13", "reslice_attempted=1"]).code).toBe(0);
    expect(JSON.parse(run(["get", "13"]).stdout).reslice_attempted).toBe(1);
  });

  it("accepts the full re-slice parent stamp in one set, resliced_to included", () => {
    // Lane 1889 (2026-08-25): resliced_to was not whitelisted, and because
    // set rejects the whole command on one unknown field, the parent lane
    // silently kept its old blocked_reason and read "waiting on Ben".
    run(["add", "14", "spec=s.md", "tier=routine"]);
    const result = run([
      "set",
      "14",
      "status=blocked",
      "blocked_reason=re-sliced automatically: remaining work is issue #99",
      "resliced_to=99"
    ]);
    expect(result.code).toBe(0);
    const record = JSON.parse(run(["get", "14"]).stdout);
    expect(record.resliced_to).toBe(99);
    expect(record.blocked_reason).toContain("re-sliced automatically");
  });

  it("updates updated_at and logs a transition on every set", async () => {
    run(["add", "10", "spec=s.md", "tier=routine"]);
    const before = JSON.parse(run(["get", "10"]).stdout).updated_at as string;
    await new Promise((r) => setTimeout(r, 10));
    run(["set", "10", "status=building"]);
    const after = JSON.parse(run(["get", "10"]).stdout).updated_at as string;
    expect(after >= before).toBe(true);

    const logLines = readFileSync(join(stateDir, "log.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((l) => JSON.parse(l));
    expect(logLines.some((l) => l.issue === 10 && l.msg.includes("status=building"))).toBe(true);
  });

  it("appends a log line with ts, issue and msg", () => {
    run(["add", "11", "spec=s.md", "tier=routine"]);
    expect(run(["log", "11", "hello", "world"]).code).toBe(0);
    const lines = readFileSync(join(stateDir, "log.jsonl"), "utf8").trim().split("\n");
    const last = JSON.parse(lines[lines.length - 1] ?? "{}");
    expect(last.issue).toBe(11);
    expect(last.msg).toBe("hello world");
    expect(typeof last.ts).toBe("string");
  });

  it("lists one line per record", () => {
    run(["add", "3", "spec=a.md", "tier=routine"]);
    run(["add", "12", "spec=b.md", "tier=security"]);
    const { stdout, code } = run(["list"]);
    expect(code).toBe(0);
    const lines = stdout.trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(lines[0]).toContain("3");
    expect(lines[1]).toContain("12");
    expect(lines[1]).toContain("security");
  });

  it("renders the board with the table, Needs Ben and Deputy rulings sections", () => {
    run(["add", "20", "spec=a.md", "tier=routine"]);
    run(["add", "21", "spec=b.md", "tier=security"]);
    run(["set", "21", "status=blocked", "blocked_reason=waiting on sign-off"]);
    run(["log", "20", "DEPUTY ruled: proceed with the smaller fix"]);

    expect(run(["board"]).code).toBe(0);
    const boardPath = join(stateDir, "board.md");
    expect(existsSync(boardPath)).toBe(true);
    const board = readFileSync(boardPath, "utf8");

    expect(board).toContain("# Fleet board");
    expect(board).toContain("#20");
    expect(board).toContain("#21");
    expect(board).toContain("## Needs Ben");
    expect(board).toContain("waiting on sign-off");
    expect(board).toContain("## Deputy rulings");
    expect(board).toContain("DEPUTY ruled: proceed with the smaller fix");
  });

  it("board shows empty-state text when nothing is blocked and no rulings exist", () => {
    run(["add", "30", "spec=a.md", "tier=routine"]);
    run(["board"]);
    const board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).toContain("Nothing right now.");
    expect(board).toContain("None.");
  });

  it("rejects add with a bad tier and duplicate add", () => {
    expect(run(["add", "40", "spec=a.md", "tier=urgent"]).code).toBe(1);
    expect(run(["add", "41", "spec=a.md", "tier=routine"]).code).toBe(0);
    expect(run(["add", "41", "spec=a.md", "tier=routine"]).code).toBe(1);
  });

  it("exits 2 with usage on an unknown command", () => {
    expect(run(["frobnicate"]).code).toBe(2);
  });

  it("new records carry pause and question fields with safe defaults", () => {
    run(["add", "42", "spec=docs/specs/x.md", "tier=routine"]);
    const record = JSON.parse(run(["get", "42"]).stdout);
    expect(record).toMatchObject({
      paused: false,
      pausedAt: null,
      pausedBy: null,
      question: null,
      questionAskedAt: null
    });
  });

  it("paused is a real boolean and rejects anything else", () => {
    run(["add", "43", "spec=docs/specs/x.md", "tier=routine"]);
    expect(run(["set", "43", "paused=true"]).code).toBe(0);
    let record = JSON.parse(run(["get", "43"]).stdout);
    expect(record.paused).toBe(true);

    expect(run(["set", "43", "paused=false"]).code).toBe(0);
    record = JSON.parse(run(["get", "43"]).stdout);
    expect(record.paused).toBe(false);

    expect(run(["set", "43", "paused=banana"]).code).toBe(1);
  });

  it("new records carry closeout fields with safe defaults", () => {
    run(["add", "50", "spec=docs/specs/x.md", "tier=routine"]);
    const record = JSON.parse(run(["get", "50"]).stdout);
    expect(record).toMatchObject({ closeout_attempts: 0, closeout_note: null });
  });

  it("a held restart ruling can be stamped, cleared, and starts null", () => {
    run(["add", "54", "spec=docs/specs/x.md", "tier=routine"]);
    let record = JSON.parse(run(["get", "54"]).stdout);
    expect(record).toMatchObject({ judgment_hold: null });

    expect(run(["set", "54", "judgment_answer=RESTART", "judgment_hold=spawn budget exhausted"]).code).toBe(0);
    record = JSON.parse(run(["get", "54"]).stdout);
    expect(record).toMatchObject({ judgment_answer: "RESTART", judgment_hold: "spawn budget exhausted" });

    expect(run(["set", "54", "judgment_answer=", "judgment_hold="]).code).toBe(0);
    record = JSON.parse(run(["get", "54"]).stdout);
    expect(record.judgment_hold).toBeFalsy();
  });

  it("board shows a banner for a lane marked done with a still-open-on-GitHub note", () => {
    run(["add", "51", "spec=a.md", "tier=routine"]);
    run(["set", "51", "status=done", "pr=900", "closeout_attempts=3", "closeout_note=still open on GitHub after 3 attempts to close it out"]);
    run(["board"]);
    const board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).toContain("## Still open on GitHub");
    expect(board).toContain("#51");
    expect(board).toContain("still open on GitHub after 3 attempts to close it out");
  });

  it("board's left-behind section lists a parked lane's branch and pull request", () => {
    run(["add", "52", "spec=a.md", "tier=routine"]);
    run(["set", "52", "status=blocked", "blocked_reason=needs a decision", "branch=fix/52-thing", "pr=901"]);
    run(["board"]);
    const board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).toContain("## Left behind");
    expect(board).toContain("#52");
    expect(board).toContain("fix/52-thing");
    expect(board).toContain("#901");
  });

  it("board's left-behind section is empty when nothing is parked with work outstanding", () => {
    run(["add", "53", "spec=a.md", "tier=routine"]);
    run(["board"]);
    const board = readFileSync(join(stateDir, "board.md"), "utf8");
    const leftBehindSection = board.split("## Left behind")[1] ?? "";
    expect(leftBehindSection).toContain("Nothing right now.");
  });

  it("question fields set and clear like other string fields", () => {
    run(["add", "44", "spec=docs/specs/x.md", "tier=routine"]);
    run([
      "set",
      "44",
      "question=Should we merge PR 90 without live proof?",
      "questionAskedAt=2026-08-23T01:00:00Z"
    ]);
    let record = JSON.parse(run(["get", "44"]).stdout);
    expect(record.question).toBe("Should we merge PR 90 without live proof?");
    expect(record.questionAskedAt).toBe("2026-08-23T01:00:00Z");

    run(["set", "44", "question=null"]);
    record = JSON.parse(run(["get", "44"]).stdout);
    expect(record.question).toBeNull();
  });

  it("new records carry worktree_attempts with a safe default of 0, and it can be set", () => {
    run(["add", "54", "spec=docs/specs/x.md", "tier=routine"]);
    const record = JSON.parse(run(["get", "54"]).stdout);
    expect(record).toMatchObject({ worktree_attempts: 0 });

    expect(run(["set", "54", "worktree_attempts=1"]).code).toBe(0);
    const updated = JSON.parse(run(["get", "54"]).stdout);
    expect(updated.worktree_attempts).toBe(1);
  });

  it("board says the run is complete once every lane is done or parked, and not otherwise", () => {
    run(["add", "60", "spec=a.md", "tier=routine"]);
    run(["set", "60", "status=done"]);
    run(["add", "61", "spec=b.md", "tier=routine"]);
    run(["set", "61", "status=blocked", "blocked_reason=needs a decision"]);
    run(["board"]);
    let board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).toContain("Run complete");

    // Add a lane that is still in progress: the run is no longer complete.
    run(["add", "62", "spec=c.md", "tier=routine"]);
    run(["board"]);
    board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).not.toContain("Run complete");
  });

  it("board does not claim the run is complete when there are no lanes at all", () => {
    run(["board"]);
    const board = readFileSync(join(stateDir, "board.md"), "utf8");
    expect(board).not.toContain("Run complete");
  });

  it("rotates the log to log.jsonl.1 once the log passes 10 MB, and keeps writing to a fresh file", () => {
    run(["add", "63", "spec=a.md", "tier=routine"]);
    const logFile = join(stateDir, "log.jsonl");
    const oversized = `${"x".repeat(10 * 1024 * 1024 + 1024)}\n`;
    writeFileSync(logFile, oversized);

    expect(run(["log", "63", "a line written after rotation"]).code).toBe(0);

    const rotatedFile = `${logFile}.1`;
    expect(existsSync(rotatedFile)).toBe(true);
    expect(readFileSync(rotatedFile, "utf8")).toBe(oversized);

    const freshLines = readFileSync(logFile, "utf8").trim().split("\n");
    expect(freshLines).toHaveLength(1);
    const last = JSON.parse(freshLines[0] ?? "{}");
    expect(last.issue).toBe(63);
    expect(last.msg).toBe("a line written after rotation");
  });

  it("rotate-log forces the same rotation on demand, for ending a run early", () => {
    const logFile = join(stateDir, "log.jsonl");
    writeFileSync(logFile, '{"ts":"2026-08-24T00:00:00.000Z","issue":"fleet","msg":"small"}\n');

    expect(run(["rotate-log"]).code).toBe(0);

    expect(existsSync(`${logFile}.1`)).toBe(true);
    expect(readFileSync(`${logFile}.1`, "utf8")).toContain("small");
    expect(existsSync(logFile)).toBe(false);
  });

  it("rotate-log does nothing when there is no log yet", () => {
    expect(run(["rotate-log"]).code).toBe(0);
    expect(existsSync(join(stateDir, "log.jsonl.1"))).toBe(false);
  });
});

describe("fleetctl stats", () => {
  // Write records and log lines directly so timestamps are under test control.
  function writeRecord(issue: number, fields: Record<string, unknown>) {
    const record = {
      issue,
      tier: "routine",
      status: "done",
      relays: 0,
      ci_fix_rounds: 0,
      qa_fix_rounds: 0,
      merge_fix_rounds: 0,
      updated_at: new Date().toISOString(),
      ...fields
    };
    const dir = join(stateDir, "tasks");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, `${issue}.json`), JSON.stringify(record, null, 2));
  }

  function writeLog(lines: Array<{ ts: string; issue: number | string; msg: string }>, file = "log.jsonl") {
    writeFileSync(join(stateDir, file), lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  }

  it("groups finished lanes by week with lead time, fix rounds, relays, and parks", () => {
    // Fixed historic dates, huge window, so week labels are deterministic.
    writeRecord(1, { relays: 2, ci_fix_rounds: 1, qa_fix_rounds: 1 });
    writeRecord(2, { relays: 0 });
    writeRecord(4, { status: "blocked" });
    writeLog([
      // week of Mon 2026-08-03: lane 1, added -> done 10h later
      { ts: "2026-08-04T00:00:00.000Z", issue: 1, msg: "added: tier=routine spec=s.md status=queued" },
      { ts: "2026-08-04T10:00:00.000Z", issue: 1, msg: "set status=done" },
      // week of Mon 2026-08-10: lane 2 (20h lead), lane 4 parked twice (counted once)
      { ts: "2026-08-11T00:00:00.000Z", issue: 2, msg: "added: tier=routine spec=s.md status=queued" },
      { ts: "2026-08-11T20:00:00.000Z", issue: 2, msg: "set status=done" },
      { ts: "2026-08-12T00:00:00.000Z", issue: 4, msg: "set status=blocked blocked_reason=x" },
      { ts: "2026-08-13T00:00:00.000Z", issue: 4, msg: "set status=blocked blocked_reason=y" },
      // fleet-level lines are ignored
      { ts: "2026-08-12T00:00:00.000Z", issue: "fleet", msg: "ALARM: something" }
    ]);

    const res = run(["stats", "--days", "36500"]);
    expect(res.code).toBe(0);
    const week1 = res.stdout.slice(res.stdout.indexOf("Week of 2026-08-03"), res.stdout.indexOf("Week of 2026-08-10"));
    expect(week1).toContain("Lanes finished: 1");
    expect(week1).toContain("Lead time, median: 10.0 hours from added to done");
    expect(week1).toContain("Fix rounds per finished lane: 2.0");
    expect(week1).toContain("Relays per finished lane: 2.0");
    expect(week1).toContain("Lanes parked for Ben: 0");
    const week2 = res.stdout.slice(res.stdout.indexOf("Week of 2026-08-10"));
    expect(week2).toContain("Lanes finished: 1");
    expect(week2).toContain("Lead time, median: 20.0 hours from added to done");
    expect(week2).toContain("Lanes parked for Ben: 1");
    expect(res.stdout).toContain("Whole window: 2 finished, median lead time 15.0 hours, 1 parked for Ben.");
  });

  it("filters by --days and reads the rotated log file too", () => {
    const now = Date.now();
    const hoursAgo = (h: number) => new Date(now - h * 3600 * 1000).toISOString();
    writeRecord(1, {});
    writeRecord(2, {});
    // Lane 1's history lives in the rotated file; lane 2 finished ~50 days ago.
    writeLog([
      { ts: hoursAgo(30), issue: 1, msg: "added: tier=routine spec=s.md status=queued" }
    ], "log.jsonl.1");
    writeLog([
      { ts: hoursAgo(20), issue: 1, msg: "set status=done" },
      { ts: hoursAgo(50 * 24 + 10), issue: 2, msg: "added: tier=routine spec=s.md status=queued" },
      { ts: hoursAgo(50 * 24), issue: 2, msg: "set status=done" }
    ]);

    const recent = run(["stats"]);
    expect(recent.code).toBe(0);
    expect(recent.stdout).toContain("Whole window: 1 finished, median lead time 10.0 hours, 0 parked for Ben.");

    const wide = run(["stats", "--days", "60"]);
    expect(wide.stdout).toContain("Whole window: 2 finished, median lead time 10.0 hours, 0 parked for Ben.");
  });

  it("copes with an empty window and rejects a bad --days", () => {
    const empty = run(["stats"]);
    expect(empty.code).toBe(0);
    expect(empty.stdout).toContain("Nothing finished or parked in this window.");

    expect(run(["stats", "--days", "zero"]).code).toBe(2);
    expect(run(["stats", "--days", "0"]).code).toBe(2);
    expect(run(["stats", "--bogus"]).code).toBe(2);
  });
});
