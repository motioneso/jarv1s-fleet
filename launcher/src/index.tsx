import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import React, { useEffect, useState } from "react";
import { Box, render, Text, useInput } from "ink";
import { Viewer } from "./view.js";
import { cloneDefaults, parseBuildAnswers, repoLooksReal, SETUP_QUESTIONS } from "./setup.js";
import { daemonActive, startDaemon } from "./operations.js";
import { clearRunEnded, readSettings, stateDir, writeRunStarted, writeSettings } from "./state.js";
import type { Settings } from "./types.js";

const DEFAULT_REPO = process.env.JARV1S_REPO || path.join(os.homedir(), "jarv1s-fleet-run");

function Setup({
  dir,
  onDone
}: {
  dir: string;
  onDone: (settings: Settings, error?: string) => void;
}) {
  const [step, setStep] = useState(0);
  const [value, setValue] = useState("");
  const [settings, setSettings] = useState(cloneDefaults());
  const [repoError, setRepoError] = useState("");
  useInput((input, key) => {
    if (key.return) {
      const next = { ...settings };
      if (step === 0) {
        const repo = path.resolve(value.trim() || DEFAULT_REPO);
        if (!repoLooksReal(repo)) {
          setRepoError(`${repo} is not a folder with a git checkout in it. Try again.`);
          return;
        }
        setRepoError("");
        next.repo = repo;
      }
      if (step === 1 && value.trim()) next.judgeCmd = value.trim();
      if (step === 2) setSettings(parseBuildAnswers(value, next));
      if (step === 3 && Number.isFinite(Number(value)) && Number(value) > 0)
        next.laneCap = Number(value);
      if (step === 4 && Number.isFinite(Number(value)) && Number(value) > 0)
        next.spawnBudget = Number(value);
      if (step === 5 && value.trim()) next.deputyEnabled = /^(y|yes|on|true)$/i.test(value.trim());
      if (step === 6 && Number.isFinite(Number(value)) && Number(value) >= 0)
        next.deputyWaitSeconds = Number(value);
      if (step === SETUP_QUESTIONS.length - 1 || (step === 5 && !next.deputyEnabled)) {
        writeSettings(dir, next);
        try {
          startDaemon(dir, next.repo);
          clearRunEnded(dir);
          writeRunStarted(dir);
          onDone(next);
        } catch (error) {
          onDone(
            next,
            error instanceof Error ? error.message : "The fleet service could not start."
          );
        }
      } else {
        setSettings(next);
        setStep(step + 1);
        setValue("");
      }
      return;
    }
    if (key.backspace || key.delete) return setValue((current) => current.slice(0, -1));
    if (input && !key.ctrl && !key.meta) setValue((current) => current + input);
  });
  const defaults =
    step === 0
      ? DEFAULT_REPO
      : step === 1
        ? "claude -p"
        : step === 2
          ? "routine program/model/effort, sensitive program/model/effort, security program/model/effort"
          : step === 3
            ? "5"
            : step === 4
              ? "30"
              : step === 5
                ? "off"
                : "1200";
  return (
    <Box flexDirection="column">
      <Text>
        {SETUP_QUESTIONS[step]} [{defaults}]
      </Text>
      <Text>&gt; {value}</Text>
      {repoError && <Text color="red">{repoError}</Text>}
    </Box>
  );
}

// Saved settings from before the repo question existed, or whose folder has
// since moved, have no usable repo. Ask the one missing question rather than
// silently building in a default folder the user never chose.
function RepoQuestion({
  dir,
  settings,
  onDone
}: {
  dir: string;
  settings: Settings;
  onDone: (settings: Settings) => void;
}) {
  const [value, setValue] = useState("");
  const [error, setError] = useState("");
  useInput((input, key) => {
    if (key.return) {
      const repo = path.resolve(value.trim() || DEFAULT_REPO);
      if (!repoLooksReal(repo)) {
        setError(`${repo} is not a folder with a git checkout in it. Try again.`);
        return;
      }
      const next = { ...settings, repo };
      writeSettings(dir, next);
      onDone(next);
      return;
    }
    if (key.backspace || key.delete) return setValue((current) => current.slice(0, -1));
    if (input && !key.ctrl && !key.meta) setValue((current) => current + input);
  });
  return (
    <Box flexDirection="column">
      <Text>Your saved settings do not name a usable project repo.</Text>
      <Text>
        {SETUP_QUESTIONS[0]} [{DEFAULT_REPO}]
      </Text>
      <Text>&gt; {value}</Text>
      {error && <Text color="red">{error}</Text>}
    </Box>
  );
}

function StartPrompt({
  dir,
  repo,
  initialError,
  onStarted,
  onQuit
}: {
  dir: string;
  repo: string;
  initialError: string;
  onStarted: () => void;
  onQuit: () => void;
}) {
  const [error, setError] = useState(initialError);
  useInput((input, key) => {
    if (input === "q") return onQuit();
    if (input === "s") {
      try {
        startDaemon(dir, repo);
        clearRunEnded(dir);
        writeRunStarted(dir);
        onStarted();
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : "The daemon could not be started.");
      }
    }
    if (key.escape) onQuit();
  });
  return (
    <Box flexDirection="column">
      <Text color="yellow">
        The fleet daemon is not running. Press [s] to start it, or [q] to quit.
      </Text>
      {error && <Text color="red">{error}</Text>}
    </Box>
  );
}

function Root() {
  const dir = stateDir();
  const [settings, setSettings] = useState<Settings | null>(() => readSettings(dir));
  const [closed, setClosed] = useState(false);
  const [started, setStarted] = useState(() => Boolean(settings && daemonActive()));
  const [daemonRunning, setDaemonRunning] = useState(() => Boolean(settings && daemonActive()));
  const [startupError, setStartupError] = useState("");
  useEffect(() => {
    if (!settings) return;
    const timer = setInterval(() => setDaemonRunning(daemonActive()), 2000);
    return () => clearInterval(timer);
  }, [settings]);
  if (closed) return null;
  if (!settings)
    return (
      <Setup
        dir={dir}
        onDone={(next, error) => {
          setSettings(next);
          setStartupError(error || "");
          setStarted(!error);
          setDaemonRunning(!error);
        }}
      />
    );
  if (!repoLooksReal(settings.repo || ""))
    return <RepoQuestion dir={dir} settings={settings} onDone={(next) => setSettings(next)} />;
  if (!daemonRunning && !started)
    return (
      <StartPrompt
        dir={dir}
        repo={settings.repo || DEFAULT_REPO}
        initialError={startupError}
        onStarted={() => {
          setStarted(true);
          setDaemonRunning(true);
          setStartupError("");
        }}
        onQuit={() => setClosed(true)}
      />
    );
  return <Viewer dir={dir} initialSettings={settings} daemonRunning={daemonRunning} />;
}

render(<Root />);
