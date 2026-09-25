#!/usr/bin/env node
// moss-sweeper: hourly cleanup of finished Moss worktrees and their leftovers.
//
// Each run:
//   1. Removes git worktrees of ~/Jarv1s that are idle, clean (build junk aside) and
//      fully on origin/main. Dirty or unmerged ones are kept and listed in kept.md.
//   2. Stops dev servers, browsers and similar processes stranded in a worktree that
//      no longer exists. SIGTERM first; SIGKILL on a later run if the same process
//      is still there.
// Weekly (stamp file), or when --weekly is passed:
//   3. Drops idle per-lane gate databases (jarvis_gate_*) in jarv1s-postgres.
//   4. Deletes stale Moss test scratch folders in /tmp.
//
// Anything ambiguous is kept and the reason logged. Never pushes, stashes, discards
// uncommitted work, deletes remote branches, or touches production.
//
// Flags: --dry-run (print only, change nothing), --weekly (run the weekly tasks now).
// Env:   MOSS_SWEEPER_REPO (default ~/Jarv1s), MOSS_SWEEPER_STATE
//        (default ~/.local/state/moss-sweeper).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HOME = os.homedir();
const HOUR = 3600;
const DAY = 24 * HOUR;

export const JUNK_DIRS = ["node_modules", "dist", ".turbo", "test-results"];
export const IN_USE_SECONDS = 6 * HOUR;
export const TMP_MAX_AGE_SECONDS = 3 * DAY;
export const WEEKLY_SECONDS = 7 * DAY;
export const GATE_DB_RE = /^jarvis_gate_[a-z0-9_]+$/;
export const TMP_DIR_RE = /^(moss|uat|playwright|vitest|jarv1s|jarvis)[-_]/i;
export const DB_CONTAINER = "jarv1s-postgres";
export const DEV_INSTANCE = "/tmp/moss-dev-main";
export const DEV_PORTS = [3000, 5173];

const PROTECTED_DBS = new Set(["jarv1s", "postgres", "template0", "template1"]);
const LOG_MAX_BYTES = 512 * 1024;
const LOG_KEEP = 3;

// Programs the process sweep may stop. Agent CLIs also run as `node`, so a node
// process is only eligible when its command line names none of them.
const STRAY_COMMS = new Set([
  "node", "vite", "tsx", "esbuild", "pnpm", "npm", "npx", "playwright",
  "chrome", "chromium", "chrome_crashpad", "chrome_crashpa", "headless_shell",
  "python", "python3"
]);
const AGENT_CMD_RE = /claude|codex|opencode|gemini|herdr|tmux|viberoom|muse|agy|acp|deepseek|glm/i;
const PROTECTED_CGROUP_RE = /moss-cli-runner|docker|containerd|prod/i;

// --- small helpers ---------------------------------------------------------------

export function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, {
    encoding: "utf8",
    timeout: opts.timeout ?? 60_000,
    maxBuffer: 16 * 1024 * 1024,
    cwd: opts.cwd,
    env: opts.env ?? process.env
  });
  return {
    ok: r.status === 0 && !r.error,
    code: r.status,
    out: r.stdout ?? "",
    err: (r.stderr ?? "") + (r.error ? String(r.error) : "")
  };
}

export function isInside(p, root) {
  if (!p || !root) return false;
  const a = path.resolve(p);
  const b = path.resolve(root);
  return a === b || a.startsWith(b.endsWith("/") ? b : b + "/");
}

export function isJunkPath(rel) {
  return rel.split("/").some((seg) => JUNK_DIRS.includes(seg));
}

// Same slug rule as ~/Jarv1s/scripts/run-gate.sh slug_for().
export function gateSlug(worktreePath) {
  return path
    .basename(worktreePath)
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, "_")
    .replace(/_+/g, "_")
    .replace(/_+$/, "")
    .slice(0, 40);
}

// --- worktree discovery ---------------------------------------------------------

export function parseWorktrees(porcelain) {
  const out = [];
  let cur = null;
  for (const line of porcelain.split("\n")) {
    if (line.startsWith("worktree ")) {
      cur = { path: line.slice(9), head: null, branch: null, detached: false, locked: false, prunable: false, bare: false };
      out.push(cur);
    } else if (!cur) {
      continue;
    } else if (line.startsWith("HEAD ")) cur.head = line.slice(5);
    else if (line.startsWith("branch ")) cur.branch = line.slice(7).replace(/^refs\/heads\//, "");
    else if (line === "detached") cur.detached = true;
    else if (line === "bare") cur.bare = true;
    else if (line.startsWith("locked")) cur.locked = true;
    else if (line.startsWith("prunable")) cur.prunable = true;
  }
  return out;
}

export function listWorktrees(repo) {
  const r = run("git", ["-C", repo, "worktree", "list", "--porcelain"]);
  if (!r.ok) throw new Error(`git worktree list failed: ${r.err.trim()}`);
  return parseWorktrees(r.out);
}

// --- worktree inspection --------------------------------------------------------

const JUNK_SPECS = JUNK_DIRS.map((d) => `:(glob)**/${d}/**`);

function statusEntries(wtPath, pathspecs) {
  const r = run("git", ["-C", wtPath, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", ...pathspecs]);
  if (!r.ok) return null;
  const tokens = r.out.split("\0").filter(Boolean);
  const out = [];
  for (let i = 0; i < tokens.length; i++) {
    const xy = tokens[i].slice(0, 2);
    out.push({ xy, file: tokens[i].slice(3) });
    if (xy.includes("R") || xy.includes("C")) i++; // -z puts the rename source in the next token
  }
  return out;
}

// git status split into real work and build junk. Pathspecs keep the two apart,
// so an untracked parent folder holding only junk is not mistaken for real work.
// Ignored files never appear.
export function dirtyEntries(wtPath) {
  const real = statusEntries(wtPath, [".", ...JUNK_SPECS.map((s) => s.replace("(glob)", "(exclude,glob)"))]);
  const junk = statusEntries(wtPath, JUNK_SPECS);
  if (!real || !junk) return null;
  return { real, junk };
}

function pruneArgs() {
  const a = ["("];
  JUNK_DIRS.forEach((d, i) => {
    if (i) a.push("-o");
    a.push("-name", d);
  });
  a.push(")", "-prune", "-o");
  return a;
}

function gitAdminMtimes(wtPath) {
  const r = run("git", ["-C", wtPath, "rev-parse", "--absolute-git-dir"]);
  if (!r.ok) return [];
  const dir = r.out.trim();
  const out = [];
  for (const f of ["HEAD", "index", "logs/HEAD"]) {
    try {
      out.push(fs.statSync(path.join(dir, f)).mtimeMs / 1000);
    } catch {}
  }
  return out;
}

// True when anything under `dir` changed after `sinceEpoch`. find stops at the first hit.
// Returns null when find fails.
// Worktree mode (default) skips build junk and folder mtimes, since creating junk bumps
// its parent and a deleted real file already shows up in git status, and also checks the
// worktree's git admin files. Scratch mode (`scratch: true`) counts everything.
export function hasRecentChange(dir, sinceEpoch, { scratch = false } = {}) {
  if (!scratch && gitAdminMtimes(dir).some((m) => m >= sinceEpoch)) return true;
  const filter = scratch ? [] : [...pruneArgs(), "-not", "-type", "d"];
  const r = run("find", [dir, ...filter, "-newermt", `@${Math.floor(sinceEpoch)}`, "-print", "-quit"], { timeout: 120_000 });
  if (r.code !== 0 && !r.out) return null;
  return r.out.trim().length > 0;
}

export function newestMtime(dir) {
  const r = run("find", [dir, ...pruneArgs(), "-printf", "%T@\\n"], { timeout: 120_000 });
  let max = 0;
  for (const l of r.out.split("\n")) {
    const n = Number(l);
    if (n > max) max = n;
  }
  for (const m of gitAdminMtimes(dir)) if (m > max) max = m;
  return max || null;
}

export function ghMergedPr(repo, branch) {
  const r = run("gh", ["pr", "list", "--state", "merged", "--head", branch, "--json", "number,headRefOid", "--limit", "5"], {
    cwd: repo,
    timeout: 30_000
  });
  // gh can print a rate-limit refusal and still exit 0, so only a parsed array counts.
  if (!r.ok) return null;
  try {
    const prs = JSON.parse(r.out);
    if (!Array.isArray(prs)) return null;
    return prs;
  } catch {
    return null;
  }
}

function isAncestor(cwd, a, b) {
  const r = run("git", ["-C", cwd, "merge-base", "--is-ancestor", a, b]);
  if (r.code === 0) return true;
  if (r.code === 1) return false;
  return null;
}

// Whether every commit of the worktree's HEAD is on main.
// -> { merged: true, how } | { merged: false, reason } | { merged: null, reason }
export function mergeState(wt, ctx) {
  const mainRef = ctx.mainRef ?? "origin/main";
  if (!wt.branch) {
    const anc = isAncestor(wt.path, wt.head, mainRef);
    if (anc === true) return { merged: true, how: "detached HEAD is on main" };
    if (anc === false) return { merged: false, reason: "detached HEAD not on main" };
    return { merged: null, reason: "could not compare detached HEAD with main" };
  }
  const c = run("git", ["-C", wt.path, "cherry", mainRef, wt.branch]);
  if (!c.ok) return { merged: null, reason: `git cherry failed: ${c.err.trim().slice(0, 200)}` };
  const unique = c.out.split("\n").filter((l) => l.startsWith("+")).length;
  if (unique === 0) return { merged: true, how: "no commits missing from main" };

  const prs = (ctx.mergedPrs ?? ((b) => ghMergedPr(ctx.repo, b)))(wt.branch);
  if (prs === null) return { merged: null, reason: `${unique} commit(s) not on main and GitHub could not be asked` };
  for (const pr of prs) {
    if (!pr.headRefOid) continue;
    if (pr.headRefOid === wt.head || isAncestor(wt.path, wt.head, pr.headRefOid) === true) {
      return { merged: true, how: `PR #${pr.number} merged` };
    }
  }
  if (prs.length) {
    return { merged: false, reason: `${unique} commit(s) not on main; merged PR #${prs[0].number} does not include the local tip` };
  }
  return { merged: false, reason: `${unique} commit(s) not on main, no merged PR` };
}

// Decide what to do with one worktree.
// -> { action: "skip" | "keep" | "remove", reason, force?, dirty?, unmerged? }
// "skip" means not a candidate right now (protected or in use); "keep" means it holds
// work that is not on main and belongs in the kept report.
export function decideWorktree(wt, ctx) {
  const now = ctx.now ?? Date.now() / 1000;
  if (wt.bare) return { action: "skip", reason: "bare repository" };
  if (path.resolve(wt.path) === path.resolve(ctx.mainPath)) {
    return { action: "skip", reason: "main checkout" };
  }
  for (const root of ctx.protectedRoots ?? []) {
    if (isInside(wt.path, root)) return { action: "skip", reason: `protected (${root})` };
  }
  if (wt.locked) return { action: "skip", reason: "worktree is locked" };
  if (wt.prunable || !fs.existsSync(wt.path)) return { action: "skip", reason: "directory already gone; prune handles it" };

  const busy = (ctx.busyPaths ?? []).find((b) => isInside(b.path, wt.path));
  if (busy) return { action: "skip", reason: `in use by ${busy.who}` };
  const recent = hasRecentChange(wt.path, now - (ctx.inUseSeconds ?? IN_USE_SECONDS));
  if (recent === null) return { action: "skip", reason: "could not read modification times" };
  if (recent) return { action: "skip", reason: "changed in the last 6 hours" };

  const dirty = dirtyEntries(wt.path);
  if (!dirty) return { action: "skip", reason: "git status failed" };
  const merge = mergeState(wt, ctx);

  if (dirty.real.length || merge.merged === false) {
    return {
      action: "keep",
      reason: [dirty.real.length ? `${dirty.real.length} uncommitted change(s)` : null, merge.merged === false ? merge.reason : null]
        .filter(Boolean)
        .join("; "),
      dirty: dirty.real,
      unmerged: merge.merged === false ? merge.reason : null
    };
  }
  if (merge.merged === null) return { action: "skip", reason: `ambiguous: ${merge.reason}` };
  return { action: "remove", reason: merge.how, force: dirty.junk.length > 0 };
}

export function removeWorktree(wt, decision, repo) {
  const args = ["-C", repo, "worktree", "remove"];
  if (decision.force) args.push("--force");
  args.push(wt.path);
  const r = run("git", args);
  if (!r.ok) return { ok: false, err: r.err.trim() };
  if (wt.branch) {
    // -D: squash merges leave the branch "unmerged" as far as git knows; the merge
    // check above is what makes this safe. Local ref only, never the remote.
    const b = run("git", ["-C", repo, "branch", "-D", wt.branch]);
    if (!b.ok) return { ok: true, branchErr: b.err.trim() };
  }
  return { ok: true };
}

// --- process table --------------------------------------------------------------

export function readProcesses(procRoot = "/proc") {
  const uid = process.getuid?.();
  const out = [];
  let pids;
  try {
    pids = fs.readdirSync(procRoot).filter((n) => /^\d+$/.test(n));
  } catch {
    return out;
  }
  for (const pid of pids) {
    const dir = path.join(procRoot, pid);
    try {
      if (uid !== undefined && fs.statSync(dir).uid !== uid) continue;
      let cwd = fs.readlinkSync(path.join(dir, "cwd"));
      const deleted = cwd.endsWith(" (deleted)");
      if (deleted) cwd = cwd.slice(0, -10);
      const stat = fs.readFileSync(path.join(dir, "stat"), "utf8");
      const rest = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      out.push({
        pid: Number(pid),
        ppid: Number(rest[1]),
        start: rest[19],
        comm: fs.readFileSync(path.join(dir, "comm"), "utf8").trim(),
        cmdline: fs.readFileSync(path.join(dir, "cmdline"), "utf8").slice(0, 4096).replace(/\0/g, " ").trim(),
        cgroup: fs.readFileSync(path.join(dir, "cgroup"), "utf8").slice(0, 2048),
        cwd,
        deleted
      });
    } catch {
      // process exited or is not ours to read
    }
  }
  return out;
}

export function paneBusyPaths() {
  const out = [];
  const h = run("herdr", ["pane", "list"], { timeout: 15_000 });
  if (h.ok) {
    try {
      for (const p of JSON.parse(h.out).result?.panes ?? []) {
        for (const k of ["cwd", "foreground_cwd"]) if (p[k]) out.push({ path: p[k], who: `herdr pane ${p.pane_id}` });
      }
    } catch {}
  }
  const t = run("tmux", ["list-panes", "-a", "-F", "#{pane_current_path}"], { timeout: 15_000 });
  if (t.ok) for (const l of t.out.split("\n")) if (l.trim()) out.push({ path: l.trim(), who: "tmux pane" });
  return { paths: out, herdrOk: h.ok };
}

export function devPortPids() {
  const r = run("ss", ["-ltnpH"], { timeout: 15_000 });
  const pids = new Set();
  for (const line of r.out.split("\n")) {
    const port = Number((line.split(/\s+/)[3] ?? "").split(":").pop());
    if (!DEV_PORTS.includes(port)) continue;
    for (const m of line.matchAll(/pid=(\d+)/g)) pids.add(Number(m[1]));
  }
  return pids;
}

// Where the worktree a path belongs to starts, when the path is a Moss worktree path.
export function worktreeRootFor(p, ctx) {
  for (const known of ctx.knownWorktrees ?? []) if (isInside(p, known)) return known;
  for (const base of ctx.worktreeBases ?? []) {
    if (isInside(p, base) && path.resolve(p) !== path.resolve(base)) {
      const rel = path.relative(base, p).split("/")[0];
      return path.join(base, rel);
    }
  }
  return null;
}

// Pick processes stranded in a Moss worktree that no longer exists.
// -> [{ proc, root }]  and  skipped: [{ proc, reason }]
export function pickStrayProcesses(procs, ctx) {
  const byPid = new Map(procs.map((p) => [p.pid, p]));
  const children = new Map();
  for (const p of procs) {
    if (!children.has(p.ppid)) children.set(p.ppid, []);
    children.get(p.ppid).push(p.pid);
  }
  // Dev-instance listeners and everything under them are off limits.
  const protectedPids = new Set();
  const stack = [...(ctx.devPids ?? [])];
  while (stack.length) {
    const pid = stack.pop();
    if (protectedPids.has(pid)) continue;
    protectedPids.add(pid);
    stack.push(...(children.get(pid) ?? []));
  }
  // So is the sweeper and its own ancestry.
  if (ctx.selfPid) protectedPids.add(ctx.selfPid);
  for (let pid = byPid.get(ctx.selfPid)?.ppid; pid && byPid.has(pid) && !protectedPids.has(pid); pid = byPid.get(pid).ppid) {
    protectedPids.add(pid);
  }

  const live = (ctx.liveWorktrees ?? []).map((p) => path.resolve(p));
  const picks = [];
  const skipped = [];
  for (const proc of procs) {
    const root = worktreeRootFor(proc.cwd, ctx);
    if (!root) continue; // not a Moss worktree path: never ours to touch
    if (isInside(proc.cwd, DEV_INSTANCE)) continue;
    const rootLive = live.includes(path.resolve(root)) && fs.existsSync(root);
    if (rootLive) {
      if (proc.deleted) skipped.push({ proc, reason: "cwd deleted but its worktree still exists" });
      continue;
    }
    if (protectedPids.has(proc.pid)) {
      skipped.push({ proc, reason: "dev instance or sweeper process" });
      continue;
    }
    if (PROTECTED_CGROUP_RE.test(proc.cgroup ?? "")) {
      skipped.push({ proc, reason: "protected service" });
      continue;
    }
    if (!STRAY_COMMS.has(proc.comm)) {
      skipped.push({ proc, reason: `program '${proc.comm}' is not on the stop list` });
      continue;
    }
    if (AGENT_CMD_RE.test(proc.cmdline)) {
      skipped.push({ proc, reason: "looks like an agent session" });
      continue;
    }
    if (/^python/.test(proc.comm) && !/http\.server/.test(proc.cmdline)) {
      skipped.push({ proc, reason: "python but not http.server" });
      continue;
    }
    picks.push({ proc, root });
  }
  return { picks, skipped };
}

// --- gate databases -------------------------------------------------------------

export function pickGateDbs(names, liveSlugs) {
  const picks = [];
  const skipped = [];
  for (const n of names) {
    if (PROTECTED_DBS.has(n) || n.startsWith("template") || !GATE_DB_RE.test(n)) continue;
    const slug = n.slice("jarvis_gate_".length);
    if (liveSlugs.has(slug)) skipped.push({ name: n, reason: "its worktree still exists" });
    else picks.push(n);
  }
  return { picks, skipped };
}

function psql(sql) {
  if (/prod/i.test(DB_CONTAINER) || DB_CONTAINER === "Moss") throw new Error("refusing a production container");
  const base = ["docker", "exec", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql];
  // Share run-gate.sh's lock so a drop never races a gate's own DROP/CREATE.
  const lock = "/tmp/jarv1s-gate/db.lock";
  return fs.existsSync(path.dirname(lock)) ? run("flock", ["-w", "60", lock, ...base], { timeout: 90_000 }) : run(base[0], base.slice(1), { timeout: 30_000 });
}

// --- /tmp scratch folders -------------------------------------------------------

export function pickTmpCandidates(entries, ctx) {
  const wts = (ctx.worktreePaths ?? []).map((p) => path.resolve(p));
  return entries.filter((e) => {
    if (!e.isDir || e.isSymlink) return false;
    if (!TMP_DIR_RE.test(e.name)) return false;
    if (/prod/i.test(e.name) || /^moss-dev/i.test(e.name) || e.name === "jarv1s-gate") return false;
    const full = path.resolve(e.path);
    if (full === path.resolve(DEV_INSTANCE)) return false;
    // Registered worktrees go through the worktree rules instead.
    if (wts.some((w) => isInside(w, full) || isInside(full, w))) return false;
    return true;
  });
}

// --- logging and state ----------------------------------------------------------

function makeLogger(stateDir, dry) {
  const logFile = path.join(stateDir, "log");
  return (msg) => {
    const line = `${new Date().toISOString()} ${dry ? "[dry-run] " : ""}${msg}`;
    console.log(line);
    if (dry) return;
    try {
      if (fs.existsSync(logFile) && fs.statSync(logFile).size > LOG_MAX_BYTES) {
        for (let i = LOG_KEEP - 1; i >= 1; i--) {
          if (fs.existsSync(`${logFile}.${i}`)) fs.renameSync(`${logFile}.${i}`, `${logFile}.${i + 1}`);
        }
        fs.renameSync(logFile, `${logFile}.1`);
      }
      fs.appendFileSync(logFile, line + "\n");
    } catch {}
  };
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, value) {
  fs.writeFileSync(file + ".tmp", JSON.stringify(value, null, 2));
  fs.renameSync(file + ".tmp", file);
}

export function renderKept(rows, now) {
  const lines = [
    "# Worktrees kept by moss-sweeper",
    "",
    `Updated ${new Date(now * 1000).toISOString()}. These hold work that is not on origin/main. Nothing here was pushed, stashed or discarded.`,
    ""
  ];
  if (!rows.length) lines.push("None.");
  for (const r of rows) {
    lines.push(`## ${r.path}`, "");
    lines.push(`- Branch: ${r.branch ?? `(detached at ${r.head?.slice(0, 9)})`}`);
    lines.push(`- Why kept: ${r.reason}`);
    if (r.dirty?.length) {
      const shown = r.dirty.slice(0, 10).map((d) => `\`${d.xy.trim() || "?"} ${d.file}\``).join(", ");
      lines.push(`- Uncommitted: ${shown}${r.dirty.length > 10 ? `, and ${r.dirty.length - 10} more` : ""}`);
    }
    lines.push(`- Last modified: ${r.mtime ? new Date(r.mtime * 1000).toISOString().slice(0, 16).replace("T", " ") : "unknown"}`, "");
  }
  return lines.join("\n");
}

// --- main -----------------------------------------------------------------------

export function main(argv = process.argv.slice(2)) {
  const dry = argv.includes("--dry-run");
  const forceWeekly = argv.includes("--weekly");
  const repo = path.resolve(process.env.MOSS_SWEEPER_REPO ?? path.join(HOME, "Jarv1s"));
  const stateDir = process.env.MOSS_SWEEPER_STATE ?? path.join(HOME, ".local/state/moss-sweeper");
  fs.mkdirSync(stateDir, { recursive: true });
  const log = makeLogger(stateDir, dry);
  const now = Date.now() / 1000;
  log(`run start${forceWeekly ? " (weekly forced)" : ""}`);

  // 1. Worktrees
  const worktrees = listWorktrees(repo);
  const knownFile = path.join(stateDir, "known-worktrees.json");
  const known = new Set(readJson(knownFile, []));
  for (const wt of worktrees) if (path.resolve(wt.path) !== repo) known.add(wt.path);

  const fetched = run("git", ["-C", repo, "fetch", "--quiet", "origin", "main"], { timeout: 120_000 });
  if (!fetched.ok) log(`WARN fetch of origin/main failed; no worktree will be removed this run: ${fetched.err.trim().slice(0, 200)}`);

  const procs = readProcesses();
  const panes = paneBusyPaths();
  if (!panes.herdrOk) log("WARN herdr pane list failed; relying on process working folders only");
  const busyPaths = [
    ...procs.filter((p) => !p.deleted).map((p) => ({ path: p.cwd, who: `pid ${p.pid} (${p.comm})` })),
    ...panes.paths
  ];
  const ctx = {
    repo,
    mainPath: repo,
    now,
    busyPaths,
    protectedRoots: [path.join(HOME, ".viberoom"), DEV_INSTANCE]
  };

  const kept = [];
  let removed = 0;
  for (const wt of worktrees) {
    let d = decideWorktree(wt, ctx);
    if (d.action === "remove" && !fetched.ok) d = { action: "skip", reason: "origin/main not refreshed this run" };
    if (d.action === "skip") {
      log(`skip ${wt.path}: ${d.reason}`);
    } else if (d.action === "keep") {
      log(`keep ${wt.path} [${wt.branch ?? "detached"}]: ${d.reason}`);
      kept.push({ ...wt, ...d, mtime: newestMtime(wt.path) });
    } else if (dry) {
      log(`would remove ${wt.path} [${wt.branch ?? "detached"}]${d.force ? " --force (build junk only)" : ""}: ${d.reason}`);
      removed++;
    } else {
      const r = removeWorktree(wt, d, repo);
      if (!r.ok) log(`ERROR could not remove ${wt.path}: ${r.err}`);
      else {
        removed++;
        log(`removed ${wt.path} [${wt.branch ?? "detached"}]${d.force ? " --force" : ""}: ${d.reason}`);
        if (r.branchErr) log(`WARN branch ${wt.branch} not deleted: ${r.branchErr}`);
      }
    }
  }
  if (!dry) {
    const p = run("git", ["-C", repo, "worktree", "prune"]);
    if (!p.ok) log(`WARN worktree prune failed: ${p.err.trim()}`);
    fs.writeFileSync(path.join(stateDir, "kept.md"), renderKept(kept, now) + "\n");
    writeJson(knownFile, [...known].sort());
  }
  log(`worktrees: ${removed} ${dry ? "would be removed" : "removed"}, ${kept.length} kept`);

  // 2. Stray processes
  const liveWorktrees = listWorktrees(repo)
    .map((w) => w.path)
    .filter((p) => fs.existsSync(p));
  const { picks, skipped } = pickStrayProcesses(readProcesses(), {
    knownWorktrees: [...known],
    worktreeBases: [path.join(repo, ".claude/worktrees"), path.join(HOME, "Jarv1s-wt")],
    liveWorktrees,
    mainPath: repo,
    devPids: devPortPids(),
    selfPid: process.pid
  });
  for (const s of skipped) log(`leave pid ${s.proc.pid} (${s.proc.comm}) in ${s.proc.cwd}: ${s.reason}`);
  const strayFile = path.join(stateDir, "strays.json");
  const prevStrays = readJson(strayFile, {});
  const nextStrays = {};
  for (const { proc, root } of picks) {
    const seenBefore = prevStrays[proc.pid] === proc.start;
    const sig = seenBefore ? "SIGKILL" : "SIGTERM";
    if (dry) {
      log(`would send ${sig} to pid ${proc.pid} (${proc.comm}) left in gone worktree ${root}: ${proc.cmdline.slice(0, 120)}`);
      continue;
    }
    try {
      process.kill(proc.pid, sig);
      nextStrays[proc.pid] = proc.start;
      log(`sent ${sig} to pid ${proc.pid} (${proc.comm}) left in gone worktree ${root}: ${proc.cmdline.slice(0, 120)}`);
    } catch (e) {
      log(`WARN could not signal pid ${proc.pid}: ${e.message}`);
    }
  }
  if (!dry) writeJson(strayFile, nextStrays);

  // 3 + 4. Weekly
  const stampFile = path.join(stateDir, "weekly-last");
  const lastWeekly = Number(readJson(stampFile, 0)) || 0;
  if (forceWeekly || now - lastWeekly >= WEEKLY_SECONDS) {
    weekly({ repo, dry, log, now, worktreePaths: liveWorktrees, busyPaths, procs: readProcesses() });
    if (!dry) writeJson(stampFile, Math.floor(now));
  } else {
    log(`weekly tasks next due ${new Date((lastWeekly + WEEKLY_SECONDS) * 1000).toISOString()}`);
  }
  log("run end");
}

function weekly({ dry, log, now, worktreePaths, busyPaths, procs }) {
  // Gate databases
  const list = psql("SELECT datname FROM pg_database");
  if (!list.ok) {
    log(`WARN could not list databases in ${DB_CONTAINER}: ${list.err.trim().slice(0, 200)}`);
  } else {
    const names = list.out.split("\n").map((s) => s.trim()).filter(Boolean);
    const liveSlugs = new Set(worktreePaths.map(gateSlug));
    const { picks, skipped } = pickGateDbs(names, liveSlugs);
    for (const s of skipped) log(`keep database ${s.name}: ${s.reason}`);
    for (const db of picks) {
      const conns = psql(`SELECT count(*) FROM pg_stat_activity WHERE datname = '${db}'`);
      if (!conns.ok || conns.out.trim() !== "0") {
        log(`keep database ${db}: ${conns.ok ? `${conns.out.trim()} active connection(s)` : "could not count connections"}`);
        continue;
      }
      if (dry) {
        log(`would drop database ${db}`);
        continue;
      }
      // No WITH (FORCE): if a connection appeared since the count, the drop fails and the database stays.
      const r = psql(`DROP DATABASE "${db}"`);
      log(r.ok ? `dropped database ${db}` : `keep database ${db}: drop failed: ${r.err.trim().slice(0, 200)}`);
    }
  }

  // /tmp scratch folders
  let entries = [];
  try {
    entries = fs.readdirSync("/tmp", { withFileTypes: true }).map((e) => ({
      name: e.name,
      path: path.join("/tmp", e.name),
      isDir: e.isDirectory(),
      isSymlink: e.isSymbolicLink()
    }));
  } catch (e) {
    log(`WARN could not list /tmp: ${e.message}`);
  }
  const uid = process.getuid?.();
  let deleted = 0;
  for (const e of pickTmpCandidates(entries, { worktreePaths })) {
    try {
      if (uid !== undefined && fs.statSync(e.path).uid !== uid) continue;
    } catch {
      continue;
    }
    const busy = busyPaths.find((b) => isInside(b.path, e.path)) ?? procs.find((p) => p.cmdline.includes(e.path));
    if (busy) {
      log(`keep ${e.path}: in use`);
      continue;
    }
    const recent = hasRecentChange(e.path, now - TMP_MAX_AGE_SECONDS, { scratch: true });
    if (recent !== false) {
      if (recent === null) log(`keep ${e.path}: could not read modification times`);
      continue;
    }
    if (dry) {
      log(`would delete ${e.path}`);
      deleted++;
      continue;
    }
    try {
      fs.rmSync(e.path, { recursive: true, force: true, maxRetries: 0 });
      deleted++;
      log(`deleted ${e.path}`);
    } catch (err) {
      log(`WARN could not delete ${e.path}: ${err.message}`);
    }
  }
  log(`scratch folders: ${deleted} ${dry ? "would be deleted" : "deleted"}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (e) {
    console.error(`moss-sweeper: ${e.stack ?? e}`);
    process.exit(1);
  }
}
