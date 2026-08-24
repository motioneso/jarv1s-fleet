import { execFile } from "node:child_process";

// Runs are opt-in: the daemon only works issues carrying this GitHub label.
// The picker screen in the viewer is what puts it on and takes it off.
export const RUN_LABEL = "fleet-run";

export type IssueRow = {
  number: number;
  title: string;
  column: string; // the board column name, e.g. "Ready" or "In progress"
  inRun: boolean; // whether the issue carries the run label
  repo: string; // owner/name, needed for the label commands
};

// Every GitHub call goes through one function so the self-check can swap in
// a fake and record exactly which commands would run.
export type RunGh = (args: string[]) => Promise<string>;

export const runGh: RunGh = (args) =>
  new Promise((resolve, reject) => {
    execFile(
      "gh",
      args,
      // The board answer includes full issue bodies; a couple hundred of
      // them can be several megabytes.
      { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error) reject(new Error(String(stderr).trim() || error.message));
        else resolve(String(stdout));
      }
    );
  });

// The same board the daemon reads, found the same way it finds it: the two
// environment variables if set, otherwise project 2 owned by the signed-in
// user.
export function boardListArgs(env: NodeJS.ProcessEnv = process.env): string[] {
  const number = env.FLEET_PROJECT_NUMBER || "2";
  const owner = env.FLEET_PROJECT_OWNER || "@me";
  return ["project", "item-list", number, "--owner", owner, "--format", "json", "--limit", "200"];
}

type BoardItem = {
  status?: string;
  labels?: string[];
  content?: { type?: string; number?: number; title?: string; repository?: string };
};

// Keep the same issues the daemon's intake keeps: real issues (not drafts),
// sitting in Ready or In Progress (the board spells it "In progress", so the
// comparison ignores case), tagged as task work.
export function parseBoardItems(json: string): IssueRow[] {
  const items = (JSON.parse(json) as { items?: BoardItem[] }).items ?? [];
  const rows: IssueRow[] = [];
  for (const item of items) {
    if (item?.content?.type !== "Issue") continue;
    if (typeof item.content.number !== "number") continue;
    const column = item.status ?? "";
    const columnLower = column.toLowerCase();
    if (columnLower !== "ready" && columnLower !== "in progress") continue;
    const labels = (item.labels ?? []).map((label) => String(label).toLowerCase());
    if (!labels.includes("task")) continue;
    // The repository comes back as "owner/name" (or occasionally a full URL).
    const repo = (item.content.repository ?? "").replace(/^https?:\/\/github\.com\//, "");
    if (!repo) continue;
    rows.push({
      number: item.content.number,
      title: item.content.title ?? "",
      column,
      inRun: labels.includes(RUN_LABEL),
      repo
    });
  }
  return rows;
}

export async function fetchIssueRows(run: RunGh = runGh): Promise<IssueRow[]> {
  return parseBoardItems(await run(boardListArgs()));
}

export function addLabelArgs(repo: string, issue: number): string[] {
  return ["issue", "edit", String(issue), "--repo", repo, "--add-label", RUN_LABEL];
}

export function removeLabelArgs(repo: string, issue: number): string[] {
  return ["issue", "edit", String(issue), "--repo", repo, "--remove-label", RUN_LABEL];
}

// --force makes this safe to run when the label already exists: it updates
// rather than fails, so creation is idempotent.
export function createLabelArgs(repo: string): string[] {
  return [
    "label",
    "create",
    RUN_LABEL,
    "--repo",
    repo,
    "--color",
    "0e8a16",
    "--description",
    "Worked by the overnight fleet",
    "--force"
  ];
}

// Add or remove the run label on one row. On success the returned rows carry
// the flipped mark; on failure the rows come back unchanged with a plain
// error message for the screen. Asking for the state a row is already in is
// a no-op (so "-" on an unmarked issue never sends a command GitHub could
// reject).
export async function setRunLabel(
  rows: IssueRow[],
  index: number,
  on: boolean,
  run: RunGh = runGh
): Promise<{ rows: IssueRow[]; error?: string }> {
  const row = rows[index];
  if (!row || row.inRun === on) return { rows };
  try {
    if (on) {
      try {
        await run(addLabelArgs(row.repo, row.number));
      } catch {
        // Adding fails when the label does not exist in that repo yet.
        // Create it (idempotently) and try the add once more; if that also
        // fails, the outer catch reports it.
        await run(createLabelArgs(row.repo));
        await run(addLabelArgs(row.repo, row.number));
      }
    } else {
      await run(removeLabelArgs(row.repo, row.number));
    }
  } catch (error) {
    return {
      rows,
      error: `Issue #${row.number}: ${error instanceof Error ? error.message : String(error)}`
    };
  }
  return { rows: rows.map((entry, i) => (i === index ? { ...entry, inRun: on } : entry)) };
}

// One list line: number, title cut to fit, board column, and a plain mark
// for whether the issue is in this run.
export function issueRowText(row: IssueRow, width = 80): string {
  const mark = row.inRun ? "in this run" : "";
  const tail = `  ${row.column}${mark ? `  ${mark}` : ""}`;
  const head = `#${row.number} `;
  const room = Math.max(8, width - head.length - tail.length);
  const title =
    row.title.length > room ? `${row.title.slice(0, Math.max(1, room - 3))}...` : row.title;
  return `${head}${title}${tail}`;
}
