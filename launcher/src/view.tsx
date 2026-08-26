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
import type { BoardIssue, Lane, LoadResult, LogEntry, Settings } from "./types.js";

const STATUS_LABELS: Record<string, string> = {
  queued: "waiting to start",
  building: "building",
  "pr-open": "waiting on checks",
  "ci-red": "checks failing",
  qa: "in review",
  "qa-red": "review found problems",
  "qa-green": "review passed",
  "qa-too-big": "review says too big",
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
  "qa-too-big",
  "merging"
]);

// Statuses where an agent is actively working right now (as opposed to
// waiting on checks or on a human): these earn the little spinner.
const WORKING_STATUSES = new Set(["building", "qa", "merging"]);

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

// A window over a long list, kept centred on the selection, so a couple
// hundred issues never overflow their panel and the cursor stays on screen.
// The caller passes how many rows actually fit; ten is only the fallback.
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

// A lane parked as "re-sliced ..." is finished here: the remaining work
// lives in a follow-up issue, so nothing about it waits on a human. Without
// this the "Waiting on you" counter and yellow tags never clear (seen live
// 2026-08-25: lane 1888 sat yellow all day after its split).
export function isSplitLane(lane: Lane): boolean {
  return lane.status === "blocked" && (lane.blocked_reason || "").startsWith("re-sliced");
}

// The distinct issue numbers a lane is waiting on: the follow-up issue it
// was split into, plus every "#NNNN" named in its block or deputy notes.
// Original order, no duplicates, and the lane's own number never counts.
export function waitingOnIssues(lane: Lane): number[] {
  const out: number[] = [];
  const add = (issue: number) => {
    if (issue > 0 && issue !== lane.issue && !out.includes(issue)) out.push(issue);
  };
  if (lane.resliced_to) add(lane.resliced_to);
  for (const text of [lane.blocked_reason, lane.deputy_reason])
    for (const match of (text || "").matchAll(/#(\d+)/g)) add(Number(match[1]));
  return out;
}

// "https://github.com/owner/repo/issues" pulled from the lane's own spec
// URL, or null when the spec is not a GitHub-style issue link.
export function issueUrlBase(spec: string | null | undefined): string | null {
  const match = (spec || "").match(/^(https?:\/\/[^/]+\/[^/]+\/[^/]+)\/issues\/\d+/);
  return match ? `${match[1]}/issues` : null;
}

// A clickable terminal link (OSC 8). Terminals without link support ignore
// the escape bytes and just print the visible text. The visible text must
// already be truncated to fit: the escape bytes are invisible, so they must
// never pass through the width-measuring truncate helper.
function issueLink(base: string | null, issue: number, visible: string): string {
  if (!base) return visible;
  return `\u001B]8;;${base}/${issue}\u0007${visible}\u001B]8;;\u0007`;
}

// One plain sentence describing where a lane actually is.
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
    case "qa-too-big":
      return "Review says the change is too big for one sitting; a piece-by-piece review is being set up.";
    case "merging":
      return "Merging now.";
    case "blocked":
      if (isSplitLane(lane)) return `Finished here: ${lane.blocked_reason}.`;
      return lane.blocked_reason ? `Waiting on you: ${lane.blocked_reason}` : "Waiting on you.";
    case "done":
      return `Finished in ${span(laneStart(state, lane.issue), lane.updated_at)}.`;
    default:
      return "Status unknown.";
  }
}

// The pipeline every lane travels, drawn as a plain text track with the lane's
// current stage bracketed, so the detail card answers "how far along is it?"
// at a glance -- the fuel bar and token label after it answer "at what cost?".
// Ben's ruling: the progress track stays AND the fuel bar shows tokens; they
// are two different things and both stay on screen.
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
    case "qa-too-big":
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

// The accent's raw channels, for mixing per-cell gradient shades.
const ACCENT_RGB = { r: 0, g: 205, b: 205 };

// The accent scaled down: 1 is the full accent, 0 is off.
function scaleAccent(scale: number): string {
  const clamped = Math.max(0, Math.min(1, scale));
  const channel = (value: number) =>
    Math.round(value * clamped)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(ACCENT_RGB.r)}${channel(ACCENT_RGB.g)}${channel(ACCENT_RGB.b)}`;
}

// One gradient cell. Two knobs blend together so the fade is smooth (Ben,
// 2026-08-25: "smaller steps and many more color shades"): the character
// density (solid block down to sparse dots) sets how much of the cell is
// ink versus real background, and the ink's color dims continuously within
// each density band. Because the ink thins out as it dims, the ramp reads
// as fading to transparent on any background, never as painting black.
function fadeCell(level: number): { char: string; color: string } {
  const t = Math.max(0, Math.min(1, level));
  if (t <= 0) return { char: " ", color: ACCENT };
  const bands: Array<[number, string]> = [
    [0.75, "█"],
    [0.5, "▓"],
    [0.25, "▒"],
    [0, "░"]
  ];
  for (const [floor, char] of bands) {
    if (t > floor) return { char, color: scaleAccent(t / (floor + 0.25)) };
  }
  return { char: "░", color: scaleAccent(t / 0.25) };
}

// What one lane can realistically burn. Calibrated 2026-08-25 against every
// Claude session on this machine from the previous two weeks (776 sessions):
// half stayed under 52k, 95% under 254k, and the single biggest session hit
// 2.46M. The ceiling sits just above that all-time max, so a full bar means
// "spending more than anything seen in two weeks". The old 200k ceiling made
// every real lane read as a full bar.
const FUEL_CEILING = 3_000_000;

// How many of the bar's cells a lane's spend fills. Exported for the tests.
export function fuelLevel(tokens: number, width = 24): number {
  return Math.max(0, Math.min(width, Math.round((tokens / FUEL_CEILING) * width)));
}

// The fuel gauge: filled cells start solid accent and dissolve to nothing
// at the fill edge (Ben's styling call, 2026-08-25), so a half-spent
// lane fades out about halfway across; the unspent tail is faint dots.
function FuelBar({ tokens, width = 24 }: { tokens: number; width?: number }) {
  const filled = fuelLevel(tokens, width);
  return (
    <Text>
      {Array.from({ length: width }, (_, index) => {
        const cell = fadeCell(1 - index / Math.max(1, filled));
        return index < filled ? (
          <Text key={index} color={cell.color}>
            {cell.char}
          </Text>
        ) : (
          <Text key={index} dimColor>
            {"."}
          </Text>
        );
      })}
    </Text>
  );
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

// The few plain lines printed into the normal terminal after the full-screen
// view closes, so a trace of the run stays in the scrollback. Plain ASCII on
// purpose: it outlives the app and its colors.
export function exitSummary(state: LoadResult, now = new Date()): string {
  const lines: string[] = [];
  if (!state.runStarted) {
    lines.push("Fleet closed. No run has been started.");
  } else if (state.runEnded) {
    lines.push(`Fleet closed. The run was ended after ${span(state.runStarted, state.runEnded)}.`);
  } else {
    lines.push(`Fleet closed. The run has been going for ${age(state.runStarted, now)}.`);
  }
  const finished = tabLanes(state, "Completed This Run");
  if (finished.length === 0) {
    lines.push("Finished this run: nothing yet.");
  } else {
    const names = finished
      .slice(0, 5)
      .map((lane) => `#${lane.issue}`)
      .join(", ");
    const more = finished.length > 5 ? ` and ${finished.length - 5} more` : "";
    lines.push(
      `Finished this run: ${finished.length} ${finished.length === 1 ? "lane" : "lanes"} (${names}${more}).`
    );
  }
  const held = state.lanes.filter((lane) => lane.status === "blocked" && !isSplitLane(lane));
  if (held.length === 0) {
    lines.push("Nothing is waiting on you.");
  } else {
    for (const lane of held.slice(0, 5)) {
      const why = lane.question || lane.blocked_reason || "needs a decision";
      lines.push(`Waiting on you: #${lane.issue} ${laneTitle(lane)} - ${why}`);
    }
    if (held.length > 5) lines.push(`Waiting on you: and ${held.length - 5} more lanes.`);
  }
  return lines.join("\n");
}

function laneStart(state: LoadResult, issue: number): string | undefined {
  return state.logs.find((entry) => entry.issue === issue && entry.ts)?.ts;
}

function span(from?: string, to?: string): string {
  if (!from || !to) return "unknown";
  const seconds = Math.max(0, Math.floor((Date.parse(to) - Date.parse(from)) / 1000));
  return duration(seconds);
}

function age(timestamp?: string, now = new Date()): string {
  if (!timestamp) return "unknown";
  return duration(Math.max(0, Math.floor((now.getTime() - Date.parse(timestamp)) / 1000)));
}

function duration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
}

// One restrained palette for the whole screen. The accent is used on purpose
// and sparingly: the app name, the selection bar, the active tab, the active
// panel's border. Yellow only ever means "a human is needed", red only means
// "broken", green only means "good", dim gray is every secondary detail.
// One exact teal everywhere. The named "cyan" renders as whatever the
// terminal theme picks, which did not match the hex gradient (Ben,
// 2026-08-25), so the accent is pinned to a hex value.
const ACCENT = "#00cdcd";
const BORDER_QUIET = "gray";

const STATUS_COLORS: Record<string, string> = {
  queued: "gray",
  building: ACCENT,
  "pr-open": ACCENT,
  "ci-red": "red",
  qa: ACCENT,
  "qa-red": "red",
  "qa-green": "green",
  "qa-too-big": "yellow",
  merging: ACCENT,
  blocked: "yellow",
  done: "green"
};

function statusLabel(lane: Lane): string {
  return STATUS_LABELS[lane.status || ""] || lane.status || "unknown";
}

// Whether one code point occupies two terminal cells (CJK, Hangul, emoji).
function isWideCodePoint(code: number): boolean {
  return (
    (code >= 0x1100 && code <= 0x115f) || // Hangul jamo
    // The next three blocks mix wide emoji (watches, check marks, stars)
    // with a few narrow symbols. All are counted wide: overcounting only
    // ends a row a cell early, while undercounting makes it wrap.
    (code >= 0x231a && code <= 0x23f3) || // watches, hourglasses, media keys
    (code >= 0x2600 && code <= 0x27bf) || // misc symbols and dingbats
    (code >= 0x2b00 && code <= 0x2b5f) || // arrows, big squares, star
    (code >= 0x2e80 && code <= 0xa4cf) || // CJK blocks
    (code >= 0xac00 && code <= 0xd7a3) || // Hangul syllables
    (code >= 0xf900 && code <= 0xfaff) || // CJK compatibility
    (code >= 0xfe30 && code <= 0xfe4f) || // CJK compatibility forms
    (code >= 0xff00 && code <= 0xff60) || // fullwidth forms
    (code >= 0xffe0 && code <= 0xffe6) ||
    (code >= 0x1f000 && code <= 0x1ffff) || // emoji and symbol planes
    (code >= 0x20000 && code <= 0x3fffd) // CJK extensions
  );
}

// Walk a string counting terminal cells, optionally stopping at a cell
// budget. Plain ASCII is one cell per character; emoji and East Asian wide
// characters take two; joiners, variation selectors and combining accents
// take none. String .length lies about all of these, and a row measured
// with .length can spill past the panel edge and wrap in the terminal.
function scanCells(text: string, budget: number): { text: string; cells: number } {
  let out = "";
  let cells = 0;
  let afterJoiner = false;
  for (const ch of text) {
    const code = ch.codePointAt(0) ?? 0;
    let cellWidth: number;
    if (code === 0x200d) {
      // Zero-width joiner glues emoji into one glyph.
      afterJoiner = true;
      cellWidth = 0;
    } else if (afterJoiner) {
      afterJoiner = false;
      cellWidth = 0;
    } else if (code === 0xfe0e || code === 0xfe0f || (code >= 0x0300 && code <= 0x036f)) {
      cellWidth = 0; // presentation selectors, combining accents
    } else {
      cellWidth = isWideCodePoint(code) ? 2 : 1;
    }
    if (cells + cellWidth > budget) break;
    out += ch;
    cells += cellWidth;
  }
  return { text: out, cells };
}

// Terminal cells the string occupies when printed.
export function displayWidth(text: string): number {
  return scanCells(text, Infinity).cells;
}

function truncate(text: string, width: number): string {
  if (width <= 0) return "";
  const whole = scanCells(text, width);
  if (whole.text === text) return text;
  if (width <= 3) return whole.text;
  return `${scanCells(text, width - 3).text}...`;
}

// Long free text (a rescue preview, a question) cut into panel-width lines
// and capped at a line budget, so nothing can ever push the footer off the
// bottom of the screen.
function boundLines(text: string, width: number, maxLines: number): string[] {
  const safeWidth = Math.max(8, width);
  const out: string[] = [];
  for (const raw of text.split("\n")) {
    if (raw === "") {
      out.push("");
      continue;
    }
    let line = raw;
    while (line.length > safeWidth) {
      out.push(line.slice(0, safeWidth));
      line = line.slice(safeWidth);
    }
    out.push(line);
  }
  if (out.length <= maxLines) return out;
  return [...out.slice(0, Math.max(1, maxLines - 1)), "(the rest is cut to fit the screen)"];
}

function clockTime(timestamp?: string): string {
  if (!timestamp) return "?";
  const time = new Date(timestamp);
  if (Number.isNaN(time.getTime())) return "?";
  return time.toTimeString().slice(0, 8);
}

// The real terminal size, kept fresh: the layout is rebuilt whenever the
// terminal window is resized.
function useTerminalSize(): { columns: number; rows: number } {
  const { stdout } = useStdout();
  const [size, setSize] = useState(() => ({
    columns: stdout?.columns ?? 80,
    rows: stdout?.rows ?? 24
  }));
  useEffect(() => {
    if (!stdout) return;
    const onResize = () =>
      setSize({ columns: stdout.columns ?? 80, rows: stdout.rows ?? 24 });
    stdout.on("resize", onResize);
    return () => {
      stdout.off("resize", onResize);
    };
  }, [stdout]);
  return size;
}

// A small plain-ASCII pulse of dots for work that is genuinely happening
// right now. Fixed width so nothing beside it jitters as it animates.
const SPINNER_FRAMES = [".  ", ".. ", "...", "   "];

function Spinner({ color = ACCENT }: { color?: string }) {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => setFrame((value) => (value + 1) % SPINNER_FRAMES.length), 400);
    return () => clearInterval(timer);
  }, []);
  return <Text color={color}>{SPINNER_FRAMES[frame]}</Text>;
}

function KeyHints({ hints }: { hints: Array<[string, string]> }) {
  return (
    <Text wrap="truncate-end">
      {hints.map(([keyName, meaning], index) => (
        <Text key={keyName}>
          {index > 0 ? <Text dimColor>{"   "}</Text> : null}
          <Text color={ACCENT}>{keyName}</Text>
          <Text dimColor> {meaning}</Text>
        </Text>
      ))}
    </Text>
  );
}

// The brand mark: the " Fleet " chip extended into a band of the accent
// color that dissolves to black about halfway across the screen (Ben's
// styling call, 2026-08-25).
function BrandBar({ width }: { width: number }) {
  const label = " Fleet ";
  const fadeLength = Math.max(0, Math.floor(width / 2) - label.length);
  return (
    <Text>
      <Text backgroundColor={ACCENT} color="black" bold>
        {label}
      </Text>
      {Array.from({ length: fadeLength }, (_, index) => {
        const cell = fadeCell(1 - (index + 1) / Math.max(1, fadeLength));
        return (
          <Text key={index} color={cell.color}>
            {cell.char}
          </Text>
        );
      })}
    </Text>
  );
}

// The one-line bar across the top: brand band on the left, run clock and the
// live indicator on the right.
function HeaderBar({
  width,
  runText,
  liveLabel,
  liveColor
}: {
  width: number;
  runText: string;
  liveLabel: string;
  liveColor: string;
}) {
  return (
    <Box paddingX={1} justifyContent="space-between">
      <BrandBar width={width} />
      <Text wrap="truncate-end">
        <Text dimColor>run </Text>
        <Text>{runText}</Text>
        <Text>{"  "}</Text>
        <Text color={liveColor} bold>
          {liveLabel}
        </Text>
      </Text>
    </Box>
  );
}

function Chip({
  label,
  value,
  valueColor
}: {
  label: string;
  value: string;
  valueColor?: string;
}) {
  return (
    <Text>
      <Text dimColor>{label} </Text>
      <Text color={valueColor} bold={Boolean(valueColor)}>
        {value}
      </Text>
    </Text>
  );
}

function ChipGap() {
  return <Text dimColor>{"  |  "}</Text>;
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
    <Text wrap="truncate-end">
      <Text dimColor>{label.padEnd(15)}</Text>
      <Text color={color}>{children}</Text>
    </Text>
  );
}

// A message centred in the empty space of its panel.
function CenteredNote({ children }: { children: React.ReactNode }) {
  return (
    <Box flexGrow={1} alignItems="center" justifyContent="center" paddingX={2}>
      <Text dimColor wrap="truncate-end">
        {children}
      </Text>
    </Box>
  );
}

// The three pieces of one list row - left text, middle padding, right text -
// sized so the row's display width never exceeds the given width, whatever
// the inputs. When both texts fit, padding fills the row to exactly width so
// the selection bar stays solid edge to edge.
export function composeRow(
  left: string,
  right: string,
  width: number
): { left: string; pad: number; right: string } {
  const rightText = truncate(right, Math.max(0, width - 10));
  const rightCells = displayWidth(rightText);
  const leftRoom = Math.max(0, width - rightCells - (rightText ? 2 : 0));
  const leftText = truncate(left, leftRoom);
  const pad = Math.max(0, width - displayWidth(leftText) - rightCells);
  return { left: leftText, pad, right: rightText };
}

// One selectable list row rendered as a full-width bar, so the selection
// reads as a solid highlight instead of scattered inverse fragments.
function RowBar({
  selected,
  width,
  left,
  right,
  leftColor,
  rightColor,
  dim
}: {
  selected: boolean;
  width: number;
  left: string;
  right: string;
  leftColor?: string;
  rightColor?: string;
  dim?: boolean;
}) {
  const { left: leftText, pad, right: rightText } = composeRow(left, right, width);
  return (
    // truncate-end is the hard backstop: even if a measurement is off, the
    // row clips at the edge instead of wrapping onto a second line.
    <Text wrap="truncate-end">
      <Text inverse={selected} color={leftColor} dimColor={dim && !selected}>
        {leftText}
      </Text>
      <Text inverse={selected}>{" ".repeat(pad)}</Text>
      <Text inverse={selected} color={rightColor} dimColor={dim && !selected}>
        {rightText}
      </Text>
    </Text>
  );
}

// The detail card for one lane: everything the old expanded view knew, laid
// out to use the panel's full height, with the log tail growing to fill it.
function LaneDetailCard({
  lane,
  state,
  dir,
  settings,
  width,
  height
}: {
  lane: Lane;
  state: LoadResult;
  dir: string;
  settings: Settings | null;
  width: number;
  height: number;
}) {
  const innerWidth = Math.max(20, width);
  const { usage } = laneUsageFor(dir, lane, settings);
  const questionLines = lane.question ? boundLines(lane.question, innerWidth - 2, 3) : [];
  const waiting = waitingOnIssues(lane);
  const issueBase = issueUrlBase(lane.spec);
  // Fixed lines above the log tail: title, blank, status, clock, track, fuel,
  // pull request, counts, optional check and waiting-on lines, question,
  // blank, log label.
  const fixed =
    9 +
    (lane.failedCheck ? 1 : 0) +
    (lane.checks?.length ? 1 : 0) +
    (waiting.length ? 1 : 0) +
    (questionLines.length || 1);
  const logBudget = Math.max(3, height - fixed);
  const logs = tailForLane(state.logs, lane.issue, logBudget);
  const working = WORKING_STATUSES.has(lane.status || "");
  return (
    <Box flexDirection="column">
      <Text bold wrap="truncate-end">
        {truncate(`#${lane.issue}  ${laneTitle(lane)}`, innerWidth)}
      </Text>
      <Text> </Text>
      <Text wrap="truncate-end">
        <Text dimColor>{"Status".padEnd(15)}</Text>
        <Text color={isSplitLane(lane) ? "gray" : STATUS_COLORS[lane.status || ""]}>
          {isSplitLane(lane) ? "split into a follow-up issue" : statusLabel(lane)}
        </Text>
        {working ? (
          <Text>
            {"  "}
            <Spinner />
          </Text>
        ) : null}
        {lane.paused ? <Text color="yellow">{"  (paused)"}</Text> : null}
      </Text>
      {lane.status === "done" ? (
        <Field label="Took">{span(laneStart(state, lane.issue), lane.updated_at)}</Field>
      ) : (
        <Field label="Working for">{age(lane.updated_at)}</Field>
      )}
      <Text wrap="truncate-end">
        <Text dimColor>{"Pipeline".padEnd(15)}</Text>
        {TRACK_STAGES.map((stage, index) => {
          const current = trackStageIndex(lane.status);
          return (
            <Text key={stage}>
              {index > 0 ? <Text dimColor>{" > "}</Text> : null}
              {index === current ? (
                <Text backgroundColor={ACCENT} color="black" bold>
                  {` ${stage} `}
                </Text>
              ) : index < current ? (
                <Text color="green">{stage}</Text>
              ) : (
                <Text dimColor>{stage}</Text>
              )}
            </Text>
          );
        })}
      </Text>
      <Text wrap="truncate-end">
        <Text dimColor>{"Tokens".padEnd(15)}</Text>
        <FuelBar tokens={usage.input + usage.output} />
        <Text> {truncate(laneTokenLabel(dir, lane, settings), Math.max(10, innerWidth - 41))}</Text>
      </Text>
      <Field label="Pull request" color={lane.pr ? undefined : "gray"}>
        {lane.pr ? `#${lane.pr}` : "none yet"}
      </Field>
      {lane.failedCheck ? (
        <Field label="Failed check" color="red">
          {truncate(lane.failedCheck, innerWidth - 15)}
        </Field>
      ) : null}
      {lane.checks?.length ? (
        <Text wrap="truncate-end">
          <Text dimColor>{"Checks".padEnd(15)}</Text>
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
        </Text>
      ) : null}
      <Text wrap="truncate-end">
        <Text dimColor>{"Handoffs".padEnd(15)}</Text>
        <Text>{String(lane.relays || 0)}</Text>
        <Text dimColor>{"   Review rounds ".padEnd(3)}</Text>
        <Text>{String(lane.qa_rounds || 0)}</Text>
      </Text>
      {waiting.length > 0
        ? (() => {
            const labels = waiting.map((issue) => `#${issue}`);
            // Truncate the visible text first, then wrap whole surviving
            // labels in link escapes; a clipped label stays plain text.
            const shown = truncate(labels.join("  "), Math.max(1, innerWidth - 15));
            return (
              <Text wrap="truncate-end">
                <Text dimColor>{"Waiting on".padEnd(15)}</Text>
                {shown.split("  ").map((part, index) => (
                  <Text key={`waiting-${index}`}>
                    {index > 0 ? "  " : ""}
                    {part === labels[index] ? issueLink(issueBase, waiting[index], part) : part}
                  </Text>
                ))}
              </Text>
            );
          })()
        : null}
      {questionLines.length > 0 ? (
        <Box flexDirection="column">
          {questionLines.map((line, index) => (
            <Text key={`question-${index}`} wrap="truncate-end">
              <Text dimColor>{(index === 0 ? "Question" : "").padEnd(15)}</Text>
              <Text color="yellow">{line}</Text>
            </Text>
          ))}
        </Box>
      ) : (
        <Field label="Question" color="gray">
          none outstanding
        </Field>
      )}
      <Text> </Text>
      <Text dimColor>Recent log</Text>
      {logs.length === 0 && <Text dimColor>{"  No log entries yet."}</Text>}
      {logs.map((entry, index) => (
        <Text key={`${entry.ts || "?"}-${index}`} wrap="truncate-end">
          <Text dimColor>{`  ${clockTime(entry.ts)}  `}</Text>
          <Text>{truncate(entry.msg || "", Math.max(4, innerWidth - 12))}</Text>
        </Text>
      ))}
    </Box>
  );
}

// The newest log entries for one lane, newest first, as many as the panel
// has room for.
function tailForLane(logs: LogEntry[], issue: number, count: number): LogEntry[] {
  return logs
    .filter((entry) => entry.issue === issue)
    .slice(-Math.max(1, count))
    .reverse();
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
  const { columns, rows } = useTerminalSize();
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

  const tooSmall = columns < 60 || rows < 12;
  if (tooSmall)
    return (
      <Box
        width={columns}
        height={rows}
        alignItems="center"
        justifyContent="center"
        flexDirection="column"
      >
        <Text color="red">The terminal is too small.</Text>
        <Text dimColor>Resize it to at least 60 columns by 12 rows.</Text>
      </Box>
    );

  const wide = columns >= 100;

  if (picker) {
    // The issue picker takes the whole screen too: header, one bordered
    // panel of board rows filling the height, key hints pinned at the bottom.
    const panelHeight = rows - 2; // header line + footer line
    const visible = Math.max(5, panelHeight - 6);
    const { start, end } = listWindow(picker.rows.length, picker.selected, visible);
    const windowRows = picker.rows.slice(start, end);
    const innerWidth = Math.max(20, columns - 6);
    return (
      <Box width={columns} height={rows} flexDirection="column">
        <Box paddingX={1} justifyContent="space-between">
          <BrandBar width={columns} />
          <Text bold>Choose issues for this run</Text>
        </Box>
        <Box
          flexGrow={1}
          flexDirection="column"
          marginX={1}
          paddingX={1}
          borderStyle="round"
          borderColor={ACCENT}
        >
          <Text dimColor>The fleet only works issues marked "in this run".</Text>
          <Text> </Text>
          {!picker.error && picker.rows.length === 0 && (
            <CenteredNote>
              Nothing in Ready or In progress on the board, or the daemon has not looked at the
              board yet.
            </CenteredNote>
          )}
          <Box flexDirection="column">
            {windowRows.map((row, offset) => {
              const index = start + offset;
              const isSelected = index === picker.selected;
              return (
                <RowBar
                  key={`${row.repo}#${row.number}`}
                  selected={isSelected}
                  width={innerWidth}
                  left={`${isSelected ? "> " : "  "}${issueRowText(row, innerWidth - 4)}`}
                  right=""
                  leftColor={row.inRun ? "green" : undefined}
                />
              );
            })}
          </Box>
          <Box flexGrow={1} />
          {picker.rows.length > windowRows.length && (
            <Text dimColor>
              Showing {start + 1}-{end} of {picker.rows.length}
            </Text>
          )}
          {picker.busy && (
            <Text color={ACCENT}>
              <Spinner /> Waiting for GitHub...
            </Text>
          )}
          {picker.error && <Text color="red" wrap="truncate-end">{picker.error}</Text>}
        </Box>
        <Box paddingX={1}>
          <KeyHints
            hints={
              columns >= 130
                ? [
                    ["up/down or j/k", "move"],
                    ["+", "add to the run"],
                    ["-", "take it out"],
                    ["r", "reload the list"],
                    ["esc or q", "back"]
                  ]
                : [
                    ["up/down", "move"],
                    ["+", "add"],
                    ["-", "remove"],
                    ["r", "reload"],
                    ["esc", "back"]
                  ]
            }
          />
        </Box>
      </Box>
    );
  }

  const alarms = fleetAlarms(state.logs);
  const liveCount = state.lanes.filter(
    (lane) => lane.status && LIVE_STATUSES.has(lane.status)
  ).length;
  const heldCount = state.lanes.filter(
    (lane) => lane.status === "blocked" && !isSplitLane(lane)
  ).length;
  const spawnsUsed = spawnsTonight(dir, state.logs);
  const tokenTotals = fleetTokenUsage(dir, state.lanes, settings ?? null);
  const runClock = state.runEnded
    ? span(state.runStarted ?? undefined, state.runEnded)
    : age(state.runStarted ?? undefined);
  const liveLabel = state.runEnded ? "ended" : daemonRunning ? "live" : "stopped";
  const liveColor = state.runEnded ? "gray" : daemonRunning ? "green" : "yellow";

  const noticeRow = !daemonRunning && !state.runEnded ? 1 : 0;
  const alarmRow = alarms.length > 0 ? 1 : 0;
  // Header, chips, footer are one line each; the body panels take the rest.
  const bodyHeight = Math.max(6, rows - 3 - noticeRow - alarmRow);

  const leftWidth = wide ? Math.max(44, Math.floor((columns - 2) * 0.4)) : columns - 2;
  // The panels sit side by side with a one-column gap (the list panel's
  // right margin); the right panel's share must not count that gap, or its
  // contents run one column past the border and wrap.
  const rightWidth = wide ? columns - 2 - leftWidth - 1 : columns - 2;
  const listInnerWidth = Math.max(20, leftWidth - 4);
  const detailInnerWidth = Math.max(20, rightWidth - 4);
  const detailInnerHeight = Math.max(4, bodyHeight - 2);

  // How many list rows fit: the panel minus borders, the tab line, a spacer,
  // and the reserved "Showing x-y of z" line. In Progress rows are two lines.
  const listCapacity = Math.max(3, bodyHeight - 2 - 3);
  const perItem = tab === "In Progress" ? 2 : 1;
  const errorRows = state.errors.length;
  const visibleCount = Math.max(3, Math.floor((listCapacity - errorRows) / perItem));
  const laneWindow = listWindow(listLength, selected, visibleCount);
  const visibleLanes = lanes.slice(laneWindow.start, laneWindow.end);
  const visibleReady = readyRows.slice(laneWindow.start, laneWindow.end);
  const overflowing = listLength > laneWindow.end - laneWindow.start;

  // What the right panel talks about: the opened lane if one is open,
  // otherwise the highlighted one, so the detail card tracks the cursor.
  const focusLane = detail ?? (tab !== "Ready" ? lanes[selected] : undefined);
  const focusReady: BoardIssue | undefined =
    tab === "Ready" ? readyRows[selected] : undefined;
  const showDetailPanel = wide || detail !== null || rescueLoading || Boolean(rescueReading);

  const alarmLine =
    alarms.length > 0 ? (
      <Box paddingX={1}>
        <Text backgroundColor="red" color="black" bold>
          {" ALARM "}
        </Text>
        <Text color="red" wrap="truncate-end">
          {" "}
          {(alarms[alarms.length - 1]?.msg ?? "").replace(/^ALARM:\s*/, "")}
        </Text>
        {alarms.length > 1 ? <Text dimColor>{`  and ${alarms.length - 1} more`}</Text> : null}
      </Box>
    ) : null;

  const listPanel = (
    <Box
      flexDirection="column"
      width={wide ? leftWidth : undefined}
      flexGrow={wide ? 0 : 1}
      marginRight={wide ? 1 : 0}
      paddingX={1}
      borderStyle="round"
      borderColor={detail ? BORDER_QUIET : ACCENT}
    >
      <Box>
        {TABS.map((name, index) => {
          const count =
            name === "Ready" ? readyRows.length : tabLanes(state, name as Tab).length;
          return (
            <Box key={name} marginRight={1}>
              {index === tabIndex ? (
                <Text bold color={ACCENT} inverse>
                  {` ${name} ${count} `}
                </Text>
              ) : (
                <Text dimColor>{` ${name} ${count} `}</Text>
              )}
            </Box>
          );
        })}
      </Box>
      <Text> </Text>
      {state.errors.map((lane) => (
          <Text key={`error-${lane.issue}`} color="red" wrap="truncate-end">
          {`#${lane.issue || "?"} has a broken lane record: ${lane.error}`}
        </Text>
      ))}
      {tab !== "Ready" &&
        state.lanes.length === 0 &&
        state.errors.length === 0 &&
        !(tab === "Completed This Run" && !state.runStarted) && (
          <CenteredNote>
            Nothing to show yet. The daemon has not written its first lane records.
          </CenteredNote>
        )}
      {tab === "Completed This Run" && !state.runStarted && (
        <CenteredNote>
          Completed This Run is unavailable because this run has no launcher start time.
        </CenteredNote>
      )}
      {tab !== "Ready" && state.lanes.length > 0 && lanes.length === 0 && state.runStarted && (
        <CenteredNote>No lanes in this tab right now.</CenteredNote>
      )}
      {tab === "Ready" && readyRows.length === 0 && (
        <CenteredNote>
          Nothing in Ready on the board, or the daemon has not looked at the board yet. Press i to
          choose issues.
        </CenteredNote>
      )}
      {tab === "In Progress" &&
        visibleLanes.map((lane, offset) => {
          const index = laneWindow.start + offset;
          const isSelected = index === selected;
          if (lane.status === "blocked") {
            // Held lanes collapse to one yellow line: there is nothing more
            // to watch happen until a human answers. A lane that was split
            // into a follow-up issue is not held - nothing waits on anyone -
            // so it shows gray, not yellow.
            const split = isSplitLane(lane);
            return (
              <RowBar
                key={lane.issue}
                selected={isSelected}
                width={listInnerWidth}
                left={`${isSelected ? "> " : "  "}#${lane.issue}  ${laneTitle(lane)}  ${
                  split
                    ? lane.blocked_reason || "split into a follow-up issue"
                    : `waiting on you${lane.blocked_reason ? `: ${lane.blocked_reason}` : ""}`
                }`}
                right=""
                leftColor={split ? "gray" : "yellow"}
              />
            );
          }
          const working = WORKING_STATUSES.has(lane.status || "");
          return (
            <Box key={lane.issue} flexDirection="column">
              <Box>
                <RowBar
                  selected={isSelected}
                  width={listInnerWidth - (working ? 4 : 0)}
                  left={`${isSelected ? "> " : "  "}#${lane.issue}  ${laneTitle(lane)}`}
                  right={statusLabel(lane)}
                  rightColor={STATUS_COLORS[lane.status || ""]}
                />
                {working ? (
                  <Text>
                    {" "}
                    <Spinner />
                  </Text>
                ) : null}
              </Box>
              <Text dimColor wrap="truncate-end">
                {/* Two spaces: the sentence lines up with the row's title
                    text, which sits after the two-cell "> " marker. */}
                {truncate(`  ${laneSentence(lane, state)}`, listInnerWidth)}
              </Text>
            </Box>
          );
        })}
      {tab === "Ready" &&
        visibleReady.map((row, offset) => {
          const index = laneWindow.start + offset;
          return (
            <RowBar
              key={`${row.repo}#${row.number}`}
              selected={index === selected}
              width={listInnerWidth}
              left={`${index === selected ? "> " : "  "}#${row.number}  ${row.title}`}
              right={row.inRun ? "in this run" : ""}
              rightColor="green"
            />
          );
        })}
      {tab === "Completed This Run" &&
        visibleLanes.map((lane, offset) => {
          const index = laneWindow.start + offset;
          return (
            <RowBar
              key={lane.issue}
              selected={index === selected}
              width={listInnerWidth}
              left={`${index === selected ? "> " : "  "}#${lane.issue}  ${laneTitle(lane)}`}
              right={`done in ${span(laneStart(state, lane.issue), lane.updated_at)}`}
              rightColor="green"
            />
          );
        })}
      <Box flexGrow={1} />
      {overflowing && (
        <Text dimColor>
          Showing {laneWindow.start + 1}-{laneWindow.end} of {listLength}; up and down to move
        </Text>
      )}
    </Box>
  );

  const detailPanel = (
    <Box
      flexDirection="column"
      flexGrow={1}
      paddingX={1}
      borderStyle="round"
      borderColor={detail || rescueReading || rescueLoading ? ACCENT : BORDER_QUIET}
    >
      {rescueLoading ? (
        <Box flexGrow={1} alignItems="center" justifyContent="center" flexDirection="column">
          <Box>
            <Spinner />
            <Text> Waiting for the rescue preview.</Text>
          </Box>
          <Text dimColor>Accept is disabled until it arrives.</Text>
        </Box>
      ) : rescueReading && detail ? (
        <Box flexDirection="column">
          <Text bold color={ACCENT}>
            Rescue preview
          </Text>
          <Text dimColor wrap="truncate-end">{`For #${detail.issue}  ${laneTitle(detail)}`}</Text>
          <Text> </Text>
          {boundLines(rescueReading, detailInnerWidth, detailInnerHeight - 4).map(
            (line, index) => (
              <Text key={`rescue-${index}`} wrap="truncate-end">
                {line}
              </Text>
            )
          )}
        </Box>
      ) : focusLane ? (
        <LaneDetailCard
          lane={focusLane}
          state={state}
          dir={dir}
          settings={settings ?? null}
          width={detailInnerWidth}
          height={detailInnerHeight}
        />
      ) : focusReady ? (
        <Box flexDirection="column">
          <Text bold wrap="truncate-end">
            {truncate(`#${focusReady.number}  ${focusReady.title}`, detailInnerWidth)}
          </Text>
          <Text> </Text>
          <Field label="Board column">{focusReady.column}</Field>
          <Field label="Repo">{focusReady.repo}</Field>
          {focusReady.inRun ? (
            <Field label="In this run" color="green">
              yes
            </Field>
          ) : (
            <Field label="In this run" color="gray">
              no; press i to add it
            </Field>
          )}
          <Box flexGrow={1} />
          <Text dimColor wrap="truncate-end">
            The board's Ready column. Press i to add or remove issues from the run.
          </Text>
        </Box>
      ) : (
        <CenteredNote>
          {tab === "Ready"
            ? "Pick an issue on the left to see it here."
            : "Pick a lane on the left to see its detail here."}
        </CenteredNote>
      )}
    </Box>
  );

  const footer = message ? (
    <Text color="yellow" wrap="truncate-end">
      {message} <Text dimColor>(press q to close)</Text>
    </Text>
  ) : endRun === "confirm" ? (
    <Text color="yellow" wrap="truncate-end">
      End the run? This stops the tick and watchdog timers. <Text bold>[y]</Text>es /{" "}
      <Text bold>[n]</Text>o
    </Text>
  ) : endRun === "choose" ? (
    <Text color="yellow" wrap="truncate-end">
      Leave running agents working, or close their panes? <Text bold>[w]</Text> leave working /{" "}
      <Text bold>[c]</Text> close panes
    </Text>
  ) : detail && action ? (
    <Text color="yellow" wrap="truncate-end">
      {action === "pause"
        ? "Pause this lane?"
        : action === "resume"
          ? "Resume this lane?"
          : "Ask for a rescue preview?"}{" "}
      <Text bold>[y]</Text>es / <Text bold>[n]</Text>o
    </Text>
  ) : detail && rescueReading ? (
    <KeyHints
      hints={[
        ["y", "accept and start the rescue"],
        ["p", "pause the lane instead"],
        ["d", "dismiss"]
      ]}
    />
  ) : detail && rescueLoading ? (
    <Text dimColor>Waiting for the rescue preview...</Text>
  ) : detail ? (
    <KeyHints
      hints={[
        ["esc", "back to the list"],
        ["p", detail.paused ? "resume this lane" : "pause this lane"],
        ["r", "ask for a rescue"]
      ]}
    />
  ) : (
    <KeyHints
      hints={
        columns >= 130
          ? [
              ["left/right", "switch tab"],
              ["up/down", "select"],
              ["enter", "open lane"],
              ["i", "choose issues"],
              ["d", settings?.deputyEnabled ? "deputy off" : "deputy on"],
              ["e", "end the run"],
              ["q", "quit"]
            ]
          : [
              ["arrows", "move"],
              ["enter", "open"],
              ["i", "issues"],
              ["d", settings?.deputyEnabled ? "deputy off" : "deputy on"],
              ["e", "end run"],
              ["q", "quit"]
            ]
      }
    />
  );

  return (
    <Box width={columns} height={rows} flexDirection="column">
      <HeaderBar
        width={columns}
        runText={state.runStarted ? runClock : "not started"}
        liveLabel={liveLabel}
        liveColor={liveColor}
      />
      <Box paddingX={1}>
        <Text wrap="truncate-end">
          <Chip label="Lanes" value={`${liveCount}/${settings?.laneCap ?? "?"}`} />
          <ChipGap />
          <Chip label="Agent starts" value={`${spawnsUsed}/${settings?.spawnBudget ?? "?"}`} />
          <ChipGap />
          <Chip
            label="Waiting on you"
            value={String(heldCount)}
            valueColor={heldCount > 0 ? "yellow" : undefined}
          />
          <ChipGap />
          <Chip
            label="Deputy"
            value={settings?.deputyEnabled ? "on" : "off"}
            valueColor={settings?.deputyEnabled ? "green" : undefined}
          />
          <ChipGap />
          <Chip
            label="Tokens, Claude lanes"
            value={`${formatTokenCount(tokenTotals.input)} in / ${formatTokenCount(tokenTotals.output)} out (+${formatTokenCount(tokenTotals.cacheRead)} cache)`}
          />
        </Text>
      </Box>
      {!daemonRunning && !state.runEnded && (
        <Box paddingX={1}>
          <Text color="yellow" wrap="truncate-end">
            The fleet daemon is not running. This is the last state it wrote. Press q to close it,
            or restart the launcher.
          </Text>
        </Box>
      )}
      {alarmLine}
      <Box flexGrow={1} flexDirection="row" paddingX={1}>
        {wide || !showDetailPanel ? listPanel : null}
        {showDetailPanel ? detailPanel : null}
      </Box>
      <Box paddingX={1}>{footer}</Box>
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
