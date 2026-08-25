import React, { useEffect, useMemo, useState } from "react";
import { Box, Text, useApp, useInput, useStdout } from "ink";
import {
  askJudge,
  acceptRescue,
  closeAgentPanes,
  logLane,
  messageAgent,
  rotateLog,
  setLane,
  stopTimers
} from "./operations.js";
import {
  fleetAlarms,
  loadState,
  logsForLane,
  markBoardIssue,
  spawnsTonight,
  writeRunEnded,
  writeSettings
} from "./state.js";
import {
  fleetTokenUsage,
  formatTokenCount,
  isClaudeLane,
  laneTokenLabel,
  laneTokenUsage
} from "./tokens.js";
import { issueRowText, setRunLabel } from "./issues.js";
import type { IssueRow } from "./issues.js";
import type { Lane, LoadResult, Settings } from "./types.js";

const STATUS_LABELS: Record<string, string> = {
  queued: "waiting to start",
  building: "building",
  "pr-open": "waiting on checks",
  "ci-red": "checks failing",
  qa: "in review",
  "qa-red": "review found problems",
  "qa-green": "review passed",
  merging: "merging",
  blocked: "waiting on you",
  done: "done"
};

// The same statuses tick.sh counts against the nightly lane cap.
const LIVE_STATUSES = new Set([
  "building",
  "pr-open",
  "ci-red",
  "qa",
  "qa-red",
  "qa-green",
  "merging"
]);

// The issue-picker screen: which board issues are in this run, plus whether
// the screen is mid-way through a label change.
type PickerState = {
  busy: boolean;
  rows: IssueRow[];
  selected: number;
  error: string;
};

type Tab = "In Progress" | "Ready" | "Completed This Run";
const TABS: Tab[] = ["In Progress", "Ready", "Completed This Run"];

export function tabLanes(state: LoadResult, tab: Tab): Lane[] {
  // The Ready tab no longer lists lane records at all: it mirrors the
  // board's Ready column from the daemon's snapshot (state.boardIssues).
  if (tab === "Ready") return [];
  if (tab === "Completed This Run") {
    const from = state.runStarted ? Date.parse(state.runStarted) : Number.POSITIVE_INFINITY;
    // Once the run has been ended, nothing that finished after that moment
    // counts -- the section freezes at what the run actually finished.
    const to = state.runEnded ? Date.parse(state.runEnded) : Number.POSITIVE_INFINITY;
    return state.lanes.filter((lane) => {
      if (lane.status !== "done") return false;
      const finished = Date.parse(lane.updated_at || "");
      return finished >= from && finished <= to;
    });
  }
  return state.lanes.filter((lane) => lane.status !== "queued" && lane.status !== "done");
}

// A short window over a long list, kept centred on the selection, so a
// couple hundred issues never overflow the terminal and the cursor is
// always on screen. Ben's ruling: ten rows at most.
export function listWindow(
  length: number,
  selected: number,
  max = 10
): { start: number; end: number } {
  const start = Math.max(0, Math.min(selected - Math.floor(max / 2), length - max));
  return { start, end: Math.min(length, start + max) };
}

function laneTitle(lane: Lane): string {
  return lane.title?.trim() || lane.spec?.split("/").pop() || `Issue #${lane.issue}`;
}

// One plain sentence describing where a lane actually is, for the third
// line of its block.
function laneSentence(lane: Lane, state: LoadResult): string {
  switch (lane.status) {
    case "building":
      return `Building for ${age(lane.updated_at)}.`;
    case "pr-open":
      return lane.pr ? `Pull request #${lane.pr} is waiting on checks.` : "Waiting on checks.";
    case "ci-red":
      return lane.failedCheck ? `A check is failing: ${lane.failedCheck}.` : "A check is failing.";
    case "qa":
      return "In review.";
    case "qa-red":
      return "Review found problems.";
    case "qa-green":
      return "Review passed; ready to merge.";
    case "merging":
      return "Merging now.";
    case "blocked":
      return lane.blocked_reason ? `Waiting on you: ${lane.blocked_reason}` : "Waiting on you.";
    case "done":
      return `Finished in ${span(laneStart(state, lane.issue), lane.updated_at)}.`;
    default:
      return "Status unknown.";
  }
}

// The pipeline every lane travels, drawn as a plain text track with the lane's
// current stage bracketed, so line two of a lane block answers "how far along
// is it?" at a glance -- the fuel bar and token label after it answer "at what
// cost?". Ben's ruling: the progress track stays AND the fuel bar shows tokens;
// they are two different things and both live on this line.
const TRACK_STAGES = ["queued", "build", "checks", "review", "merge", "done"] as const;

function trackStageIndex(status?: string): number {
  switch (status) {
    case "queued":
      return 0;
    case "building":
      return 1;
    case "pr-open":
    case "ci-red":
      return 2;
    case "qa":
    case "qa-red":
    case "qa-green":
      return 3;
    case "merging":
      return 4;
    case "done":
      return 5;
    default:
      return -1; // unknown status: draw the track with no stage marked
  }
}

export function progressTrack(lane: Lane): string {
  const current = trackStageIndex(lane.status);
  return TRACK_STAGES.map((stage, index) => (index === current ? `[${stage}]` : stage)).join(
    " > "
  );
}

// A plain text bar so tokens spent show at a glance, the way a fuel gauge
// does, without pretending to know a dollar cost.
function fuelBar(tokens: number, width = 16): string {
  const softCeiling = 200_000;
  const filled = Math.max(0, Math.min(width, Math.round((tokens / softCeiling) * width)));
  return `[${"#".repeat(filled)}${"-".repeat(width - filled)}]`;
}

export function story(lane: Lane, state: LoadResult): string {
  const logs = logsForLane(state.logs, lane.issue)
    .map((entry) => `${entry.ts || "?"} ${entry.msg || ""}`)
    .join("\n");
  return [
    `Issue #${lane.issue}: ${laneTitle(lane)}`,
    `Status: ${STATUS_LABELS[lane.status || ""] || lane.status || "unknown"}`,
    lane.status === "done"
      ? `Took: ${span(laneStart(state, lane.issue), lane.updated_at)}`
      : `Working for: ${age(lane.updated_at)}`,
    `Pull request: ${lane.pr ? `#${lane.pr}` : "none"}`,
    lane.failedCheck ? `Failed check: ${lane.failedCheck}` : "",
    lane.checks?.length
      ? `Checks: ${lane.checks.map((check) => `${check.name || "check"} (${check.state || "unknown"})`).join(", ")}`
      : "",
    `Relays: ${lane.relays || 0}; review rounds: ${lane.qa_rounds || 0}`,
    lane.question ? `Question: ${lane.question}` : "No outstanding question.",
    logs ? `Recent log:\n${logs}` : "No log entries yet."
  ].join("\n");
}

function laneStart(state: LoadResult, issue: number): string | undefined {
  return state.logs.find((entry) => entry.issue === issue && entry.ts)?.ts;
}

function span(from?: string, to?: string): string {
  if (!from || !to) return "unknown";
  const seconds = Math.max(0, Math.floor((Date.parse(to) - Date.parse(from)) / 1000));
  return duration(seconds);
}

function age(timestamp?: string): string {
  if (!timestamp) return "unknown";
  return duration(Math.max(0, Math.floor((Date.now() - Date.parse(timestamp)) / 1000)));
}

function duration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
}

// One restrained palette for the whole screen: cyan for what is active or
// selected, yellow for anything waiting on a human, green for good outcomes,
// red for failures, gray for secondary detail.
const STATUS_COLORS: Record<string, string> = {
  queued: "gray",
  building: "cyan",
  "pr-open": "cyan",
  "ci-red": "red",
  qa: "cyan",
  "qa-red": "red",
  "qa-green": "green",
  merging: "cyan",
  blocked: "yellow",
  done: "green"
};

function statusLabel(lane: Lane): string {
  return STATUS_LABELS[lane.status || ""] || lane.status || "unknown";
}

function truncate(text: string, width: number): string {
  if (width <= 0) return "";
  if (text.length <= width) return text;
  if (width <= 3) return text.slice(0, width);
  return `${text.slice(0, width - 3)}...`;
}

function clockTime(timestamp?: string): string {
  if (!timestamp) return "?";
  const time = new Date(timestamp);
  if (Number.isNaN(time.getTime())) return "?";
  return time.toTimeString().slice(0, 8);
}

function Divider({ width }: { width: number }) {
  return <Text color="gray">{"─".repeat(Math.max(1, width))}</Text>;
}

function KeyHints({ hints }: { hints: Array<[string, string]> }) {
  return (
    <Text>
      {hints.map(([keyName, meaning], index) => (
        <Text key={keyName}>
          {index > 0 ? <Text dimColor>{"   "}</Text> : null}
          <Text color="cyan">{keyName}</Text>
          <Text dimColor> {meaning}</Text>
        </Text>
      ))}
    </Text>
  );
}

function Field({
  label,
  color,
  children
}: {
  label: string;
  color?: string;
  children: React.ReactNode;
}) {
  return (
    <Text>
      <Text dimColor>{label.padEnd(15)}</Text>
      <Text color={color}>{children}</Text>
    </Text>
  );
}

function LaneDetail({ lane, state, width }: { lane: Lane; state: LoadResult; width: number }) {
  const logs = logsForLane(state.logs, lane.issue);
  const innerWidth = Math.max(20, width - 4);
  return (
    <Box flexDirection="column" marginTop={1} paddingX={1} borderStyle="round" borderColor="gray">
      <Text bold>{truncate(`Issue #${lane.issue}  ${laneTitle(lane)}`, innerWidth)}</Text>
      <Box marginTop={1} flexDirection="column">
        <Field label="Status" color={STATUS_COLORS[lane.status || ""]}>
          {statusLabel(lane)}
          {lane.paused ? <Text color="yellow">  (paused)</Text> : null}
        </Field>
        {lane.status === "done" ? (
          <Field label="Took">{span(laneStart(state, lane.issue), lane.updated_at)}</Field>
        ) : (
          <Field label="Working for">{age(lane.updated_at)}</Field>
        )}
        <Field label="Pull request" color={lane.pr ? undefined : "gray"}>
          {lane.pr ? `#${lane.pr}` : "none yet"}
        </Field>
        {lane.failedCheck ? (
          <Field label="Failed check" color="red">
            {lane.failedCheck}
          </Field>
        ) : null}
        {lane.checks?.length ? (
          <Field label="Checks">
            {lane.checks.map((check, index) => (
              <Text
                key={`${check.name || "check"}-${index}`}
                color={
                  check.state === "success"
                    ? "green"
                    : check.state === "failure" || check.state === "error"
                      ? "red"
                      : "gray"
                }
              >
                {index > 0 ? "  " : ""}
                {check.name || "check"} ({check.state || "unknown"})
              </Text>
            ))}
          </Field>
        ) : null}
        <Field label="Agent handoffs">{String(lane.relays || 0)}</Field>
        <Field label="Review rounds">{String(lane.qa_rounds || 0)}</Field>
        {lane.question ? (
          <Box flexDirection="column">
            <Text dimColor>Question</Text>
            <Box paddingLeft={2}>
              <Text color="yellow">{lane.question}</Text>
            </Box>
          </Box>
        ) : (
          <Field label="Question" color="gray">
            none outstanding
          </Field>
        )}
      </Box>
      <Box marginTop={1} flexDirection="column">
        <Text dimColor>Recent log</Text>
        {logs.length === 0 && <Text color="gray">  No log entries yet.</Text>}
        {logs.map((entry, index) => (
          <Text key={`${entry.ts || "?"}-${index}`}>
            <Text dimColor>  {clockTime(entry.ts)}  </Text>
            {truncate(entry.msg || "", Math.max(4, innerWidth - 12))}
          </Text>
        ))}
      </Box>
    </Box>
  );
}

// One list line for a lane: cursor, issue number, title cut to fit, status in
// its state colour, then any badges. Used by the In Progress headlines and the
// Completed This Run rows so both read the same way.
function LaneLine({ lane, selected, width }: { lane: Lane; selected: boolean; width: number }) {
  const cursor = selected ? "> " : "  ";
  const issueText = `#${lane.issue}`;
  const status = statusLabel(lane);
  const badges = [lane.pr ? `PR #${lane.pr}` : "", lane.paused ? "paused" : ""]
    .filter(Boolean)
    .join("  ");
  const room =
    width -
    cursor.length -
    issueText.length -
    4 -
    status.length -
    (badges ? badges.length + 2 : 0);
  const title = truncate(laneTitle(lane), Math.max(8, room));
  return (
    <Box>
      <Text inverse={selected} color={selected ? "cyan" : "gray"}>
        {cursor}
        {issueText}
        {"  "}
      </Text>
      <Text inverse={selected} color={lane.question ? "yellow" : undefined}>
        {title}
        {"  "}
      </Text>
      <Text inverse={selected} color={STATUS_COLORS[lane.status || ""]}>
        {status}
      </Text>
      {badges ? (
        <Text inverse={selected} dimColor>
          {"  "}
          {badges}
        </Text>
      ) : null}
    </Box>
  );
}

function ActionPrompt({ children }: { children: React.ReactNode }) {
  return (
    <Text color="yellow">
      {children} <Text bold>[y]</Text>es / <Text bold>[n]</Text>o
    </Text>
  );
}

export function Viewer({
  dir,
  initialSettings,
  daemonRunning,
  onQuit
}: {
  dir: string;
  initialSettings?: Settings;
  daemonRunning: boolean;
  onQuit?: () => void;
}) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const [state, setState] = useState<LoadResult>(() => loadState(dir));
  const [tabIndex, setTabIndex] = useState(0);
  const [selected, setSelected] = useState(0);
  const [detail, setDetail] = useState<Lane | null>(null);
  const [action, setAction] = useState<"pause" | "resume" | "rescue-confirm" | null>(null);
  const [endRun, setEndRun] = useState<"confirm" | "choose" | null>(null);
  const [message, setMessage] = useState("");
  const [rescueReading, setRescueReading] = useState<string | null>(null);
  const [rescueLoading, setRescueLoading] = useState(false);
  const [picker, setPicker] = useState<PickerState | null>(null);

  // The rows come from the daemon's board snapshot on disk -- opening the
  // picker never asks GitHub anything (a direct board read costs about a
  // fifth of the hourly GraphQL allowance). "r" re-reads the same snapshot.
  const openPicker = () => {
    setPicker({ busy: false, rows: loadState(dir).boardIssues, selected: 0, error: "" });
  };
  const settings = state.settings || initialSettings;
  const tab = TABS[tabIndex] ?? "In Progress";
  const lanes = useMemo(() => tabLanes(state, tab), [state, tab]);
  // The Ready tab mirrors the board's Ready column, read from the daemon's
  // snapshot on disk -- so the screen never asks GitHub anything itself.
  const readyRows = useMemo(
    () => state.boardIssues.filter((row) => row.column.toLowerCase() === "ready"),
    [state.boardIssues]
  );
  const listLength = tab === "Ready" ? readyRows.length : lanes.length;

  useEffect(() => {
    const timer = setInterval(() => setState(loadState(dir)), 2000);
    return () => clearInterval(timer);
  }, [dir]);

  useEffect(() => {
    if (selected >= listLength) setSelected(Math.max(0, listLength - 1));
  }, [listLength, selected]);

  const quit = () => {
    onQuit?.();
    exit();
  };

  useInput((input, key) => {
    if (message) {
      if (input === "q" || key.escape) setMessage("");
      return;
    }
    if (picker) {
      if (input === "q" || key.escape) return setPicker(null);
      if (key.upArrow || input === "k")
        return setPicker({ ...picker, selected: Math.max(0, picker.selected - 1) });
      if (key.downArrow || input === "j")
        return setPicker({
          ...picker,
          selected: Math.min(Math.max(0, picker.rows.length - 1), picker.selected + 1)
        });
      if (picker.busy) return;
      if (input === "r") return openPicker();
      if (input === "+" || input === "-") {
        const index = picker.selected;
        const on = input === "+";
        setPicker({ ...picker, busy: true, error: "" });
        void setRunLabel(picker.rows, index, on).then((result) => {
          // On success, carry the flipped mark into the daemon's snapshot so
          // the Ready tab agrees with this screen right away.
          const changed = picker.rows[index];
          if (!result.error && changed) markBoardIssue(dir, changed.number, on);
          setPicker((current) =>
            current
              ? { ...current, busy: false, rows: result.rows, error: result.error ?? "" }
              : current
          );
        });
      }
      return;
    }
    if (endRun === "confirm") {
      if (input === "y") return setEndRun("choose");
      if (input === "n" || key.escape) return setEndRun(null);
      return;
    }
    if (endRun === "choose") {
      if (key.escape) return setEndRun(null);
      if (input !== "w" && input !== "c") return;
      const closePanes = input === "c";
      try {
        stopTimers();
        if (closePanes) {
          const runningAgents = state.lanes
            .filter((lane) => lane.agent && lane.status !== "done" && lane.status !== "blocked")
            .map((lane) => lane.agent as string);
          closeAgentPanes(runningAgents);
        }
        writeRunEnded(dir);
        logLane(
          dir,
          "fleet",
          `human ended the run, ${closePanes ? "closing running agent panes" : "leaving running agents working"}`
        );
        rotateLog(dir);
        setEndRun(null);
        setMessage("Run ended. Both timers are stopped.");
      } catch (error) {
        setEndRun(null);
        setMessage(
          error instanceof Error ? error.message : "Ending the run failed partway through."
        );
      }
      return;
    }
    if (!detail) {
      if (input === "q") return quit();
      if (input === "e") return setEndRun("confirm");
      if (input === "i") return openPicker();
      if (input === "d" && settings) {
        const deputyEnabled = !settings.deputyEnabled;
        writeSettings(dir, { ...settings, deputyEnabled });
        setState((current) => ({ ...current, settings: { ...settings, deputyEnabled } }));
        setMessage(`Deputy turned ${deputyEnabled ? "on" : "off"}.`);
        return;
      }
      if (key.leftArrow) return setTabIndex((value) => (value + TABS.length - 1) % TABS.length);
      if (key.rightArrow) return setTabIndex((value) => (value + 1) % TABS.length);
      if (key.upArrow) return setSelected((value) => Math.max(0, value - 1));
      if (key.downArrow)
        return setSelected((value) => Math.min(Math.max(0, listLength - 1), value + 1));
      // Ready rows are board issues, not lanes: there is no lane detail to
      // open for them, so Enter only works on the lane tabs.
      if (key.return && tab !== "Ready" && lanes[selected]) return setDetail(lanes[selected]);
      return;
    }
    if (rescueLoading) return;
    if (rescueReading) {
      if (input === "y") {
        const used = spawnsTonight(dir, state.logs);
        if (!settings || used >= settings.spawnBudget) {
          setMessage(
            `Rescue cannot start: the ${settings?.spawnBudget || 0}-start budget is exhausted.`
          );
        } else {
          try {
            acceptRescue(dir, detail, rescueReading);
            setMessage("Rescue agent started.");
            setRescueReading(null);
          } catch (error) {
            setMessage(error instanceof Error ? error.message : "Rescue could not start.");
          }
        }
      } else if (input === "p") {
        setAction(detail.paused ? "resume" : "pause");
        setRescueReading(null);
      } else if (input === "d" || key.escape) {
        setRescueReading(null);
      }
      return;
    }
    if (action) {
      if (input === "n" || key.escape) return setAction(null);
      if (input !== "y") return;
      if (action === "rescue-confirm") {
        if (!settings) return setMessage("Settings are not available yet.");
        setAction(null);
        setRescueLoading(true);
        void askJudge(settings, story(detail, state))
          .then((answer) => {
            setRescueLoading(false);
            setRescueReading(answer);
          })
          .catch((error) => {
            setRescueLoading(false);
            setRescueReading(null);
            setMessage(
              error instanceof Error ? error.message : "The judgment call failed; nothing changed."
            );
          });
        return;
      }
      try {
        const paused = action === "pause";
        setLane(
          dir,
          detail.issue,
          `paused=${paused}`,
          `pausedAt=${paused ? new Date().toISOString() : "null"}`,
          `pausedBy=${paused ? "human" : "null"}`
        );
        messageAgent(
          detail.agent,
          paused
            ? "Pause this lane at the next safe point and wait."
            : "The lane is resumed. Continue working."
        );
        logLane(dir, detail.issue, `human ${paused ? "paused" : "resumed"} the lane`);
        setAction(null);
        setMessage(paused ? "Lane paused." : "Lane resumed.");
      } catch (error) {
        setMessage(error instanceof Error ? error.message : "The lane action failed.");
        setAction(null);
      }
      return;
    }
    if (key.escape) return setDetail(null);
    if (input === "p") return setAction(detail.paused ? "resume" : "pause");
    if (input === "r") return setAction("rescue-confirm");
  });

  const tooSmall =
    stdout.columns !== undefined &&
    stdout.rows !== undefined &&
    (stdout.columns < 60 || stdout.rows < 12);
  if (tooSmall)
    return (
      <Text color="red">
        The terminal is too small. Resize it to at least 60 columns by 12 rows.
      </Text>
    );

  if (picker) {
    const width = stdout.columns ?? 80;
    // The board can hold a couple hundred issues; show a window of rows
    // around the selection so the screen never overflows the terminal.
    const visible = Math.max(5, Math.min(10, (stdout.rows ?? 24) - 9));
    const { start, end } = listWindow(picker.rows.length, picker.selected, visible);
    const windowRows = picker.rows.slice(start, end);
    return (
      <Box flexDirection="column" paddingX={1}>
        <Text bold color="cyan">
          Choose issues for this run
        </Text>
        <Divider width={Math.max(1, width - 2)} />
        <Text color="gray">The fleet only works issues marked "in this run".</Text>
        {!picker.error && picker.rows.length === 0 && (
          <Box marginTop={1}>
            <Text color="gray">
              {"  "}Nothing in Ready or In progress on the board, or the daemon has not looked at
              the board yet.
            </Text>
          </Box>
        )}
        <Box flexDirection="column" marginTop={1}>
          {windowRows.map((row, offset) => {
            const index = start + offset;
            const isSelected = index === picker.selected;
            return (
              <Text
                key={`${row.repo}#${row.number}`}
                inverse={isSelected}
                color={row.inRun ? "green" : undefined}
              >
                {isSelected ? "> " : "  "}
                {issueRowText(row, width - 4)}
              </Text>
            );
          })}
        </Box>
        {picker.rows.length > windowRows.length && (
          <Text color="gray">
            Showing {start + 1}-{end} of {picker.rows.length}
          </Text>
        )}
        {picker.busy && <Text color="cyan">Waiting for GitHub...</Text>}
        {picker.error && <Text color="red">{picker.error}</Text>}
        <Box marginTop={1}>
          <KeyHints
            hints={[
              ["up/down or j/k", "move"],
              ["+", "add to the run"],
              ["-", "take it out"],
              ["r", "reload the list"],
              ["esc or q", "back"]
            ]}
          />
        </Box>
      </Box>
    );
  }

  const alarms = fleetAlarms(state.logs);
  const liveCount = state.lanes.filter((lane) => lane.status && LIVE_STATUSES.has(lane.status)).length;
  const heldCount = state.lanes.filter((lane) => lane.status === "blocked").length;
  const spawnsUsed = spawnsTonight(dir, state.logs);
  const tokenTotals = fleetTokenUsage(dir, state.lanes, settings ?? null);
  const runClock = state.runEnded
    ? span(state.runStarted ?? undefined, state.runEnded)
    : age(state.runStarted ?? undefined);
  const liveLabel = state.runEnded ? "ended" : daemonRunning ? "live" : "stopped";
  const liveColor = state.runEnded ? "gray" : daemonRunning ? "green" : "yellow";
  const laneWindow = listWindow(listLength, selected);
  const visibleLanes = lanes.slice(laneWindow.start, laneWindow.end);
  const visibleReady = readyRows.slice(laneWindow.start, laneWindow.end);

  const width = Math.max(40, (stdout.columns ?? 80) - 2);

  return (
    <Box flexDirection="column" paddingX={1}>
      <Box justifyContent="space-between">
        <Text bold color="cyan">
          Fleet
        </Text>
        <Text>
          <Text dimColor>Run </Text>
          {state.runStarted ? runClock : "not started"}
          <Text color={liveColor}>{`  ${liveLabel}`}</Text>
        </Text>
      </Box>
      <Divider width={width} />
      {!daemonRunning && !state.runEnded && (
        <Text color="yellow">
          The fleet daemon is not running. This is the last state it wrote. Press q to close it, or
          restart the launcher.
        </Text>
      )}
      <Text>
        <Text dimColor>Lanes </Text>
        {liveCount}/{settings?.laneCap ?? "?"}
        <Text dimColor>   Agent starts </Text>
        {spawnsUsed}/{settings?.spawnBudget ?? "?"}
        <Text dimColor>   Waiting on you </Text>
        {heldCount}
        <Text dimColor>   Deputy </Text>
        {settings?.deputyEnabled ? <Text color="green">on</Text> : <Text dimColor>off</Text>}
      </Text>
      <Text color="gray">
        Tokens this run, Claude lanes only: {formatTokenCount(tokenTotals.input)} in /{" "}
        {formatTokenCount(tokenTotals.output)} out (+{formatTokenCount(tokenTotals.cacheRead)}{" "}
        from cache)
      </Text>
      {alarms.map((entry, index) => (
        <Text key={`${entry.ts ?? ""}-${index}`} color="red">
          {"! "}
          {(entry.msg ?? "").replace(/^ALARM:\s*/, "")}
        </Text>
      ))}
      <Box marginTop={1}>
        {TABS.map((name, index) => (
          <Box key={name} marginRight={2}>
            {index === tabIndex ? (
              <Text bold color="cyan" inverse>
                {` ${name} `}
              </Text>
            ) : (
              <Text dimColor>{` ${name} `}</Text>
            )}
          </Box>
        ))}
      </Box>
      <Box flexDirection="column" marginTop={1}>
        {state.errors.map((lane) => (
          <Text key={`error-${lane.issue}`} color="red">
            {"  "}#{lane.issue || "?"} has a broken lane record: {lane.error}
          </Text>
        ))}
        {tab !== "Ready" &&
          state.lanes.length === 0 &&
          state.errors.length === 0 &&
          !(tab === "Completed This Run" && !state.runStarted) && (
            <Text color="gray">
              {"  "}Nothing to show yet. The daemon has not written its first lane records.
            </Text>
          )}
        {tab === "Completed This Run" && !state.runStarted && (
          <Text color="gray">
            {"  "}Completed This Run is unavailable because this run has no launcher start time.
          </Text>
        )}
        {tab !== "Ready" && state.lanes.length > 0 && lanes.length === 0 && state.runStarted && (
          <Text color="gray">{"  "}No lanes in this tab right now.</Text>
        )}
        {tab === "Ready" && (
          <Text color="gray">
            {"  "}The board's Ready column. Press i to add or remove issues from the run.
          </Text>
        )}
        {tab === "Ready" && readyRows.length === 0 && (
          <Text color="gray">
            {"  "}Nothing in Ready on the board, or the daemon has not looked at the board yet.
          </Text>
        )}
        {listLength > laneWindow.end - laneWindow.start && (
          <Text color="gray">
            {"  "}Showing {laneWindow.start + 1}-{laneWindow.end} of {listLength}; up/down to move
          </Text>
        )}
        {tab === "In Progress" &&
          visibleLanes.map((lane, offset) => {
            const index = laneWindow.start + offset;
            const isSelected = index === selected;
            if (lane.status === "blocked") {
              // Held lanes collapse to one dim line: there is nothing more to
              // watch happen until a human answers.
              return (
                <Text key={lane.issue} color="yellow" dimColor={!isSelected} inverse={isSelected}>
                  {truncate(
                    `${isSelected ? "> " : "  "}#${lane.issue}  ${laneTitle(lane)}  waiting on you${
                      lane.blocked_reason ? `: ${lane.blocked_reason}` : ""
                    }`,
                    width
                  )}
                </Text>
              );
            }
            const { usage } = laneUsageFor(dir, lane, settings ?? null);
            return (
              <Box key={lane.issue} flexDirection="column" marginBottom={1}>
                <LaneLine lane={lane} selected={isSelected} width={width} />
                <Text color="gray">
                  {truncate(
                    `      ${progressTrack(lane)}  ${fuelBar(usage.input + usage.output)} ${laneTokenLabel(dir, lane, settings ?? null)}`,
                    width
                  )}
                </Text>
                <Text color="gray">{truncate(`      ${laneSentence(lane, state)}`, width)}</Text>
              </Box>
            );
          })}
        {tab === "Ready" &&
          visibleReady.map((row, offset) => {
            const index = laneWindow.start + offset;
            return (
              <Text
                key={`${row.repo}#${row.number}`}
                inverse={index === selected}
                color={row.inRun ? "green" : undefined}
              >
                {index === selected ? "> " : "  "}
                {issueRowText(row, width - 2)}
              </Text>
            );
          })}
        {tab === "Completed This Run" &&
          visibleLanes.map((lane, offset) => (
            <LaneLine
              key={lane.issue}
              lane={lane}
              selected={laneWindow.start + offset === selected}
              width={width}
            />
          ))}
      </Box>
      {detail && <LaneDetail lane={detail} state={state} width={width} />}
      <Box marginTop={1}>
        {detail ? (
          <KeyHints
            hints={[
              ["esc", "back to the list"],
              ["p", detail.paused ? "resume this lane" : "pause this lane"],
              ["r", "ask for a rescue"]
            ]}
          />
        ) : (
          <KeyHints
            hints={[
              ["left/right", "switch tab"],
              ["up/down", "select"],
              ["enter", "open lane"],
              ["i", "choose issues"],
              ["d", settings?.deputyEnabled ? "deputy off" : "deputy on"],
              ["e", "end the run"],
              ["q", "quit"]
            ]}
          />
        )}
      </Box>
      {detail && action && (
        <ActionPrompt>
          {action === "pause"
            ? "Pause this lane?"
            : action === "resume"
              ? "Resume this lane?"
              : "Ask for a rescue preview?"}
        </ActionPrompt>
      )}
      {detail && rescueLoading && (
        <Text color="cyan">
          Waiting for the rescue preview. Accept is disabled until it arrives.
        </Text>
      )}
      {detail && rescueReading && (
        <Box
          flexDirection="column"
          marginTop={1}
          paddingX={1}
          borderStyle="round"
          borderColor="cyan"
        >
          <Text bold color="cyan">
            Rescue preview
          </Text>
          <Text>{rescueReading}</Text>
          <Box marginTop={1}>
            <KeyHints
              hints={[
                ["y", "accept and start the rescue"],
                ["p", "pause the lane instead"],
                ["d", "dismiss"]
              ]}
            />
          </Box>
        </Box>
      )}
      {endRun === "confirm" && (
        <Box marginTop={1}>
          <ActionPrompt>End the run? This stops the tick and watchdog timers.</ActionPrompt>
        </Box>
      )}
      {endRun === "choose" && (
        <Box marginTop={1}>
          <Text color="yellow">
            Leave running agents working, or close their panes? <Text bold>[w]</Text> leave working
            / <Text bold>[c]</Text> close panes
          </Text>
        </Box>
      )}
      {message && (
        <Box marginTop={1}>
          <Text color="yellow">
            {message} <Text dimColor>(press q to close)</Text>
          </Text>
        </Box>
      )}
    </Box>
  );
}

// Zero for a non-Claude lane, since there is no transcript to sum -- the
// fuel bar for those lanes should stay empty, not draw a false zero fill.
function laneUsageFor(dir: string, lane: Lane, settings: Settings | null) {
  if (!settings || !isClaudeLane(lane, settings))
    return { usage: { input: 0, output: 0, cacheRead: 0 } };
  return { usage: laneTokenUsage(dir, lane).usage };
}
