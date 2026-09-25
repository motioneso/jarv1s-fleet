import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decideWorktree,
  removeWorktree,
  listWorktrees,
  pickStrayProcesses,
  pickGateDbs,
  pickTmpCandidates,
  gateSlug,
  isJunkPath,
  hasRecentChange
} from "../sweeper/moss-sweeper.mjs";

// Every repo here is a throwaway under the OS temp dir. "origin" is a local bare repo,
// so nothing touches the network or GitHub; merged-PR answers are injected.

let root: string;
let origin: string;
let main: string;
const FUTURE = Date.now() / 1000 + 7 * 3600; // makes every fresh file look 7 hours old

function git(cwd: string, ...args: string[]) {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" }
  }).trim();
}

function commit(cwd: string, file: string, body = file) {
  writeFileSync(join(cwd, file), body);
  git(cwd, "add", file);
  git(cwd, "commit", "-qm", `add ${file}`);
}

function addWorktree(name: string, branch?: string) {
  const p = join(root, "wt", name);
  if (branch) git(main, "worktree", "add", "-q", "-b", branch, p, "origin/main");
  else git(main, "worktree", "add", "-q", "--detach", p, "origin/main");
  return p;
}

function wtRecord(p: string) {
  return listWorktrees(main).find((w: { path: string }) => w.path === p)!;
}

function ctx(extra: Record<string, unknown> = {}) {
  return { repo: main, mainPath: main, now: FUTURE, busyPaths: [], protectedRoots: [], mergedPrs: () => [], ...extra };
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "sweeper-test-"));
  origin = join(root, "origin.git");
  main = join(root, "main");
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
  execFileSync("git", ["clone", "-q", origin, main], { stdio: "ignore" });
  git(main, "checkout", "-qb", "main");
  writeFileSync(join(main, ".gitignore"), "dist/\n");
  git(main, "add", ".gitignore");
  commit(main, "a.txt");
  git(main, "push", "-q", "origin", "main");
  git(main, "fetch", "-q", "origin");
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe("decideWorktree: remove", () => {
  it("removes a branch whose commits are all on main", () => {
    const p = addWorktree("merged", "feat/merged");
    commit(p, "b.txt");
    git(p, "push", "-q", "origin", "HEAD:main");
    git(main, "fetch", "-q", "origin");
    const d = decideWorktree(wtRecord(p), ctx());
    expect(d.action).toBe("remove");
    expect(d.force).toBe(false);
  });

  it("removes a squash-merged branch when GitHub reports a merged PR at its tip", () => {
    const p = addWorktree("squashed", "feat/squashed");
    commit(p, "c.txt");
    commit(p, "c2.txt");
    const tip = git(p, "rev-parse", "HEAD");
    writeFileSync(join(main, "c2.txt"), "c2.txt");
    commit(main, "c.txt", "c.txt"); // the squash commit: both files in one commit
    git(main, "push", "-q", "origin", "main");
    commit(main, "later.txt"); // main moves on past the merge
    git(main, "push", "-q", "origin", "main");
    git(main, "fetch", "-q", "origin");
    const d = decideWorktree(wtRecord(p), ctx({ mergedPrs: () => [{ number: 7, headRefOid: tip }] }));
    expect(d).toMatchObject({ action: "remove", reason: "PR #7 merged" });
  });

  it("removes a detached HEAD that is an ancestor of main", () => {
    const p = addWorktree("detached");
    expect(decideWorktree(wtRecord(p), ctx()).action).toBe("remove");
  });

  it("needs --force when the only dirt is untracked build junk", () => {
    const p = addWorktree("junky", "feat/junky");
    mkdirSync(join(p, "node_modules/x"), { recursive: true });
    writeFileSync(join(p, "node_modules/x/i.js"), "1");
    mkdirSync(join(p, "packages/web/test-results"), { recursive: true });
    writeFileSync(join(p, "packages/web/test-results/r.json"), "1");
    const d = decideWorktree(wtRecord(p), ctx());
    expect(d).toMatchObject({ action: "remove", force: true });
  });

  it("really removes the worktree and local branch, and leaves the remote alone", () => {
    const p = addWorktree("gone", "feat/gone");
    git(p, "push", "-q", "origin", "feat/gone");
    mkdirSync(join(p, "dist"));
    writeFileSync(join(p, "dist/out.js"), "1");
    const wt = wtRecord(p);
    const d = decideWorktree(wt, ctx());
    expect(d.action).toBe("remove");
    expect(removeWorktree(wt, d, main).ok).toBe(true);
    expect(existsSync(p)).toBe(false);
    expect(git(main, "branch", "--list", "feat/gone")).toBe("");
    expect(git(origin, "branch", "--list", "feat/gone")).toContain("feat/gone");
  });
});

describe("decideWorktree: keep", () => {
  it("keeps uncommitted tracked changes", () => {
    const p = addWorktree("dirty", "feat/dirty");
    writeFileSync(join(p, "a.txt"), "changed");
    const d = decideWorktree(wtRecord(p), ctx());
    expect(d.action).toBe("keep");
    expect(d.dirty.map((x: { file: string }) => x.file)).toEqual(["a.txt"]);
  });

  it("keeps a new untracked source file", () => {
    const p = addWorktree("untracked", "feat/untracked");
    writeFileSync(join(p, "notes.md"), "x");
    expect(decideWorktree(wtRecord(p), ctx()).action).toBe("keep");
  });

  it("keeps unique commits with no merged PR", () => {
    const p = addWorktree("unmerged", "feat/unmerged");
    commit(p, "d.txt");
    const d = decideWorktree(wtRecord(p), ctx());
    expect(d.action).toBe("keep");
    expect(d.unmerged).toMatch(/1 commit\(s\) not on main, no merged PR/);
  });

  it("keeps commits made after the PR merged", () => {
    const p = addWorktree("after", "feat/after");
    commit(p, "e.txt");
    const prTip = git(p, "rev-parse", "HEAD");
    commit(p, "f.txt");
    const d = decideWorktree(wtRecord(p), ctx({ mergedPrs: () => [{ number: 9, headRefOid: prTip }] }));
    expect(d.action).toBe("keep");
    expect(d.reason).toMatch(/does not include the local tip/);
  });

  it("keeps a detached HEAD that is not on main", () => {
    const p = addWorktree("detached-off");
    commit(p, "g.txt");
    expect(decideWorktree(wtRecord(p), ctx()).action).toBe("keep");
  });

  it("does not remove when GitHub cannot be asked", () => {
    const p = addWorktree("nogh", "feat/nogh");
    commit(p, "h.txt");
    const d = decideWorktree(wtRecord(p), ctx({ mergedPrs: () => null }));
    expect(d.action).toBe("skip");
    expect(d.reason).toMatch(/ambiguous/);
  });
});

describe("decideWorktree: skip", () => {
  it("skips the main checkout", () => {
    expect(decideWorktree(wtRecord(main), ctx())).toMatchObject({ action: "skip", reason: "main checkout" });
  });

  it("skips protected roots such as the dev instance and viberoom", () => {
    const p = addWorktree("devlike");
    expect(decideWorktree(wtRecord(p), ctx({ protectedRoots: [join(root, "wt")] })).action).toBe("skip");
  });

  it("skips a worktree with a process working inside it", () => {
    const p = addWorktree("busy", "feat/busy");
    const d = decideWorktree(wtRecord(p), ctx({ busyPaths: [{ path: join(p, "packages"), who: "pid 42 (node)" }] }));
    expect(d).toMatchObject({ action: "skip", reason: "in use by pid 42 (node)" });
  });

  it("skips a worktree whose pane sits inside it", () => {
    const p = addWorktree("pane", "feat/pane");
    expect(decideWorktree(wtRecord(p), ctx({ busyPaths: [{ path: p, who: "herdr pane w1:p1" }] })).action).toBe("skip");
  });

  it("skips a worktree changed in the last 6 hours, even with nothing to lose", () => {
    const p = addWorktree("fresh", "feat/fresh");
    const d = decideWorktree(wtRecord(p), ctx({ now: Date.now() / 1000 }));
    expect(d).toMatchObject({ action: "skip", reason: "changed in the last 6 hours" });
  });

  it("ignores recent changes that are only build junk", () => {
    const p = addWorktree("oldjunk", "feat/oldjunk");
    const now = Date.now() / 1000;
    // Age every real file, then write only junk now.
    execFileSync("find", [p, "-exec", "touch", "-h", "-d", "@" + Math.floor(now - 7 * 3600), "{}", "+"]);
    const admin = git(p, "rev-parse", "--absolute-git-dir");
    execFileSync("find", [admin, "-exec", "touch", "-d", "@" + Math.floor(now - 7 * 3600), "{}", "+"]);
    mkdirSync(join(p, "node_modules"));
    writeFileSync(join(p, "node_modules/new.js"), "1");
    expect(decideWorktree(wtRecord(p), ctx({ now })).action).toBe("remove");
  });
});

describe("pickStrayProcesses", () => {
  const base = "/home/u/Jarv1s/.claude/worktrees";
  const proc = (over: Record<string, unknown>) => ({
    pid: 100, ppid: 1, start: "1", comm: "node", cmdline: "node vite", cgroup: "0::/user.slice", cwd: `${base}/agent-x/apps/web`, deleted: true, ...over
  });
  const pctx = (extra: Record<string, unknown> = {}) => ({
    knownWorktrees: [], worktreeBases: [base], liveWorktrees: [], mainPath: "/home/u/Jarv1s", devPids: new Set(), selfPid: 1, ...extra
  });

  it("picks a dev server left in a removed worktree", () => {
    const { picks } = pickStrayProcesses([proc({})], pctx());
    expect(picks.map((p: { proc: { pid: number } }) => p.proc.pid)).toEqual([100]);
  });

  it("picks python http.server but not other python", () => {
    const { picks } = pickStrayProcesses(
      [proc({ pid: 11, comm: "python3", cmdline: "python3 -m http.server 8000" }), proc({ pid: 12, comm: "python3", cmdline: "python3 job.py" })],
      pctx()
    );
    expect(picks.map((p: { proc: { pid: number } }) => p.proc.pid)).toEqual([11]);
  });

  it("never picks agents, shells, services or the dev instance", () => {
    const procs = [
      proc({ pid: 1, cmdline: "node /home/u/.local/bin/claude --print" }),
      proc({ pid: 2, comm: "bash", cmdline: "-bash" }),
      proc({ pid: 3, cgroup: "0::/user.slice/app.slice/moss-cli-runner.service" }),
      proc({ pid: 4, ppid: 1 }), // child of a dev-port listener
      proc({ pid: 5, cwd: "/tmp/moss-dev-main/apps/api" }),
      proc({ pid: 6, cwd: "/home/u/elsewhere" }),
      proc({ pid: 7, cwd: "/home/u/Jarv1s/apps/web" })
    ];
    const { picks } = pickStrayProcesses(procs, pctx({ devPids: new Set([1]) }));
    expect(picks).toEqual([]);
  });

  it("leaves processes in a worktree that still exists", () => {
    const live = mkdtempSync(join(tmpdir(), "sweeper-live-"));
    try {
      const { picks } = pickStrayProcesses([proc({ cwd: live, deleted: false })], pctx({ knownWorktrees: [live], liveWorktrees: [live] }));
      expect(picks).toEqual([]);
    } finally {
      rmSync(live, { recursive: true, force: true });
    }
  });

  it("uses recorded /tmp worktree paths to recognise a gone /tmp worktree", () => {
    const { picks } = pickStrayProcesses([proc({ cwd: "/tmp/moss-p1-base/apps" })], pctx({ knownWorktrees: ["/tmp/moss-p1-base"] }));
    expect(picks).toHaveLength(1);
  });
});

describe("pickGateDbs", () => {
  it("drops only gate copies whose worktree is gone", () => {
    const names = ["jarv1s", "postgres", "template0", "template1", "jarvis_gate_agent_a1", "jarvis_gate_live_one", "other_db"];
    const { picks, skipped } = pickGateDbs(names, new Set(["live_one"]));
    expect(picks).toEqual(["jarvis_gate_agent_a1"]);
    expect(skipped.map((s: { name: string }) => s.name)).toEqual(["jarvis_gate_live_one"]);
  });

  it("matches run-gate.sh's slug rule", () => {
    expect(gateSlug("/x/.claude/worktrees/Agent-A8B0.f")).toBe("agent_a8b0_f");
  });
});

describe("pickTmpCandidates", () => {
  it("keeps the dev instance, the gate folder, prod names and registered worktrees out", () => {
    const e = (name: string, over = {}) => ({ name, path: `/tmp/${name}`, isDir: true, isSymlink: false, ...over });
    const out = pickTmpCandidates(
      [e("moss-dev-main"), e("jarv1s-gate"), e("moss-prod-index"), e("moss-p1-base"), e("uat-seed-x"), e("playwright-artifacts-1"), e("random"), e("vitest-a", { isSymlink: true }), e("jarv1s-web-a", { isDir: false })],
      { worktreePaths: ["/tmp/moss-p1-base"] }
    );
    expect(out.map((x: { name: string }) => x.name)).toEqual(["uat-seed-x", "playwright-artifacts-1"]);
  });
});

describe("hasRecentChange in scratch mode", () => {
  it("counts a freshly made empty folder as recent", () => {
    const d = mkdtempSync(join(tmpdir(), "sweeper-scratch-"));
    try {
      expect(hasRecentChange(d, Date.now() / 1000 - 3600, { scratch: true })).toBe(true);
      expect(hasRecentChange(d, Date.now() / 1000 + 3600, { scratch: true })).toBe(false);
    } finally {
      rmSync(d, { recursive: true, force: true });
    }
  });
});

describe("isJunkPath", () => {
  it("recognises build junk at any depth", () => {
    expect(isJunkPath("packages/web/dist/x.js")).toBe(true);
    expect(isJunkPath(".turbo/")).toBe(true);
    expect(isJunkPath("src/distance.ts")).toBe(false);
  });
});
