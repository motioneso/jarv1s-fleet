export type Tier = "routine" | "sensitive" | "security";

// "tool" is the agent program that runs the work, e.g. the local Claude CLI.
export type BuildModel = { tool: string; model: string; effort: string };

export type Settings = {
  repo: string;
  // Every project folder this launcher has ever been pointed at, most recent
  // first, so switching back to a previous project is a pick, not a re-type.
  repoHistory?: string[];
  judgeCmd: string;
  buildModels: Record<Tier, BuildModel>;
  laneCap: number;
  spawnBudget: number;
  deputyEnabled: boolean;
  deputyWaitSeconds: number;
  memoryFloorMb: number;
};

export type Lane = {
  issue: number;
  title?: string | null;
  spec?: string | null;
  tier?: Tier;
  status?: string;
  branch?: string | null;
  worktree?: string | null;
  pr?: number | null;
  agent?: string | null;
  // Which model this lane's agent is actually running on, recorded by the
  // daemon at spawn time. Absent on records written before that existed.
  agent_model?: string | null;
  agent_effort?: string | null;
  agent_tool?: string | null;
  relays?: number;
  qa_rounds?: number;
  blocked_reason?: string | null;
  deputy_reason?: string | null;
  resliced_to?: number | null;
  paused?: boolean;
  pausedAt?: string | null;
  pausedBy?: string | null;
  question?: string | null;
  questionAskedAt?: string | null;
  checks?: Array<{ name?: string; state?: string }>;
  failedCheck?: string | null;
  updated_at?: string;
  error?: string;
};

export type LogEntry = { ts?: string; issue?: number | string; msg?: string };

// One row of the daemon's board snapshot: a Ready / In progress issue as the
// GitHub board shows it. Matches the chooser's IssueRow shape on purpose.
export type BoardIssue = {
  number: number;
  title: string;
  column: string;
  inRun: boolean;
  repo: string;
};

export type LoadResult = {
  lanes: Lane[];
  boardIssues: BoardIssue[];
  errors: Lane[];
  logs: LogEntry[];
  runStarted: string | null;
  runEnded: string | null;
  settings: Settings | null;
};
