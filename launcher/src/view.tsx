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
  spawnsSince,
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

type Tab = "In Progress" | "Ready" | "Completed This Run";
const TABS: Tab[] = ["In Progress", "Ready", "Completed This Run"];

export function tabLanes(state: LoadResult, tab: Tab): Lane[] {
  if (tab === "Ready") return state.lanes.filter((lane) => lane.status === "queued");
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

function laneTitle(lane: Lane): string {
  return lane.title?.trim() || lane.spec?.split("/").pop() || `Issue #${lane.issue}`;
}

// Colour carries lane state: a glance at the list should say the same thing
// the words do.
function laneColor(lane: Lane): string | undefined {
  if (lane.status === "blocked") return "yellow";
  if (lane.status === "ci-red" || lane.status === "qa-red") return "red";
  if (lane.status === "qa-green" || lane.status === "merging") return "green";
  if (lane.status === "done") return "gray";
  return undefined;
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

function ActionPrompt({ children }: { children: React.ReactNode }) {
  return <Text color="yellow">{children} [y]es / [n]o</Text>;
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
  const settings = state.settings || initialSettings;
  const tab = TABS[tabIndex] ?? "In Progress";
  const lanes = useMemo(() => tabLanes(state, tab), [state, tab]);

  useEffect(() => {
    const timer = setInterval(() => setState(loadState(dir)), 2000);
    return () => clearInterval(timer);
  }, [dir]);

  useEffect(() => {
    if (selected >= lanes.length) setSelected(Math.max(0, lanes.length - 1));
  }, [lanes.length, selected]);

  const quit = () => {
    onQuit?.();
    exit();
  };

  useInput((input, key) => {
    if (message) {
      if (input === "q" || key.escape) setMessage("");
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
        return setSelected((value) => Math.min(Math.max(0, lanes.length - 1), value + 1));
      if (key.return && lanes[selected]) return setDetail(lanes[selected]);
      return;
    }
    if (rescueLoading) return;
    if (rescueReading) {
      if (input === "y") {
        const used = spawnsSince(state.logs);
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

  const alarms = fleetAlarms(state.logs);
  const liveCount = state.lanes.filter((lane) => lane.status && LIVE_STATUSES.has(lane.status)).length;
  const heldCount = state.lanes.filter((lane) => lane.status === "blocked").length;
  const spawnsUsed = spawnsSince(state.logs);
  const tokenTotals = fleetTokenUsage(dir, state.lanes, settings ?? null);
  const runClock = state.runEnded
    ? span(state.runStarted ?? undefined, state.runEnded)
    : age(state.runStarted ?? undefined);
  const liveLabel = state.runEnded ? "ended" : daemonRunning ? "live" : "stopped";
  const liveColor = state.runEnded ? "gray" : daemonRunning ? "green" : "yellow";

  return (
    <Box flexDirection="column" padding={1}>
      {!daemonRunning && !state.runEnded && (
        <Text color="yellow">
          The fleet daemon is not running. This is the last state it wrote. Press q to close it, or
          restart the launcher.
        </Text>
      )}
      <Box>
        <Text>
          Run: {state.runStarted ? runClock : "not started"} ({liveLabel}
          <Text color={liveColor}>{" "}●</Text>) Lanes: {liveCount}/{settings?.laneCap ?? "?"} Spawns:{" "}
          {spawnsUsed}/{settings?.spawnBudget ?? "?"} Held: {heldCount} Deputy:{" "}
          {settings?.deputyEnabled ? "on" : "off"}
        </Text>
      </Box>
      <Box>
        <Text color="gray">
          Tokens this run, Claude lanes only: {formatTokenCount(tokenTotals.input)} in /{" "}
          {formatTokenCount(tokenTotals.output)} out (+{formatTokenCount(tokenTotals.cacheRead)}{" "}
          from cache)
        </Text>
      </Box>
      {alarms.map((entry, index) => (
        <Text key={`${entry.ts ?? ""}-${index}`} color="red">
          {(entry.msg ?? "").replace(/^ALARM:\s*/, "")}
        </Text>
      ))}
      <Box>
        {TABS.map((name, index) => (
          <Text
            key={name}
            bold={index === tabIndex}
            color={index === tabIndex ? "cyan" : undefined}
          >
            {index === tabIndex ? `[ ${name} ]` : `  ${name}  `}
          </Text>
        ))}
      </Box>
      <Text>←/→ tabs  ↑/↓ select  Enter detail  d deputy  e end run  q quit</Text>
      <Box flexDirection="column" marginTop={1}>
        {state.errors.map((lane) => (
          <Text key={`error-${lane.issue}`} color="red">
            # {lane.issue || "?"} error: {lane.error}
          </Text>
        ))}
        {state.lanes.length === 0 &&
          state.errors.length === 0 &&
          !(tab === "Completed This Run" && !state.runStarted) && (
            <Text color="gray">
              The daemon has not ticked yet. Waiting for the first lane records.
            </Text>
          )}
        {tab === "Completed This Run" && !state.runStarted && (
          <Text color="gray">
            Completed This Run is unavailable because this run has no launcher start time.
          </Text>
        )}
        {state.lanes.length > 0 && lanes.length === 0 && state.runStarted && (
          <Text color="gray">No lanes in this tab.</Text>
        )}
        {tab === "In Progress" &&
          lanes.map((lane, index) => {
            const isSelected = index === selected;
            const cursor = isSelected ? "❯ " : "  ";
            if (lane.status === "blocked") {
              // Held lanes collapse to one dim line: there is nothing more to
              // watch happen until a human answers.
              return (
                <Text key={lane.issue} color="yellow" dimColor={!isSelected} inverse={isSelected}>
                  {cursor}# {lane.issue} {laneTitle(lane)} -- waiting on you
                  {lane.blocked_reason ? `: ${lane.blocked_reason}` : ""}
                </Text>
              );
            }
            const { usage } = laneUsageFor(dir, lane, settings ?? null);
            return (
              <Box key={lane.issue} flexDirection="column" marginBottom={1}>
                <Text color={laneColor(lane)} inverse={isSelected}>
                  {cursor}# {lane.issue} {laneTitle(lane)} --{" "}
                  {STATUS_LABELS[lane.status || ""] || lane.status || "unknown"}
                  {lane.pr ? ` (PR #${lane.pr})` : ""}
                  {lane.paused ? " [paused]" : ""}
                </Text>
                <Text color="gray">
                  {"    "}
                  {fuelBar(usage.input + usage.output)} {laneTokenLabel(dir, lane, settings ?? null)}
                </Text>
                <Text color="gray">{"    "}{laneSentence(lane, state)}</Text>
              </Box>
            );
          })}
        {tab !== "In Progress" &&
          lanes.map((lane, index) => (
            <Text
              key={lane.issue}
              color={lane.question || lane.status === "blocked" ? "yellow" : undefined}
              inverse={index === selected}
            >
              {index === selected ? "❯ " : "  "}#{lane.issue} {laneTitle(lane)} --{" "}
              {STATUS_LABELS[lane.status || ""] || lane.status || "unknown"}
              {lane.pr ? ` (PR #${lane.pr})` : ""}
              {lane.paused ? " [paused]" : ""}
            </Text>
          ))}
      </Box>
      {detail && (
        <Box flexDirection="column" marginTop={1}>
          <Text bold>{story(detail, state)}</Text>
          <Box marginTop={1}>
            <Text>Esc: back p: pause/resume r: rescue</Text>
          </Box>
          {action && (
            <ActionPrompt>
              {action === "pause"
                ? "Pause this lane?"
                : action === "resume"
                  ? "Resume this lane?"
                  : "Ask for a rescue preview?"}
            </ActionPrompt>
          )}
          {rescueLoading && (
            <Text color="cyan">
              Waiting for the rescue preview. Accept is disabled until it arrives.
            </Text>
          )}
          {rescueReading && (
            <Text color="cyan">
              {`Rescue preview:\n${rescueReading}\n\n[y] accept  [p] pause  [d] dismiss`}
            </Text>
          )}
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
            Leave running agents working, or close their panes? [w] leave working / [c] close panes
          </Text>
        </Box>
      )}
      {message && (
        <Box marginTop={1}>
          <Text color="yellow">{message} (q to close)</Text>
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
