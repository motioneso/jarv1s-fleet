#!/usr/bin/env bash
# Fleet daemon tick: one pass over every lane record, advance each one step, exit.
# Spec: docs/superpowers/specs/2026-08-23-fleet-daemon.md (issue #1894).
# Runs as a systemd oneshot on a 1-minute timer (see scripts/ops/systemd/).
#
# Safety rails, checked before anything else every tick:
#   - STOP file in the state dir: exit immediately, do nothing, say nothing.
#   - Spawn budget: at most 30 agent spawns per night (since 18:00 local); at the
#     cap, nothing new is dispatched. The last fifth of the budget is held back
#     for recovery spawns only (a fix agent, a respawned reviewer); fresh lanes
#     stop dispatching once the rest is used, so recovery never runs dry.
#   - Deputy switch (deputyEnabled in settings.json): lets a one-shot model call
#     stand in for Ben on parked lanes, within a hard floor it may never cross.
#
# FLEET_DRY_RUN=1 prints every externally-visible action as "DRY: <command>"
# instead of running it (worktree add, herdr, gh writes, needs-ben, claude -p,
# and all record writes through fleetctl). Read-only queries (gh pr checks,
# gh pr view, herdr agent list, herdr pane list) still run so the state machine
# can be exercised against stubbed commands in tests.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The product checkout this fleet works in. The tooling lives in its own repo, so this
# is configuration rather than "two folders up from this script".
REPO_ROOT="${JARV1S_REPO:-$HOME/jarv1s-fleet-run}"
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "fleet: JARV1S_REPO does not point at a git checkout: $REPO_ROOT" >&2
  exit 1
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
STATE_DIR="${JARV1S_FLEET_STATE:-$HOME/.local/state/jarv1s-fleet}"
TASKS_DIR="$STATE_DIR/tasks"
LOG_FILE="$STATE_DIR/log.jsonl"
BRIEFS_DIR="$STATE_DIR/briefs"
BRIEF_TEMPLATE="${FLEET_BRIEF_TEMPLATE:-$SCRIPT_DIR/brief-template.md}"
NEEDS_BEN_DIR="${NEEDS_BEN_DIR:-$HOME/.needs-ben}"
DRY="${FLEET_DRY_RUN:-0}"
# FLEET_SANDBOX=1 runs every lane agent inside scripts/agent-sandbox.sh
# (bubblewrap: the whole box is read-only, writes allowed only in the lane's
# own folders; network stays on). Implemented as exported shell functions
# injected into the agent pane's environment, so the "claude" / "codex" the
# pane runs is the sandbox wrapper. Default off; see the plan's rollout note.
SANDBOX="${FLEET_SANDBOX:-0}"
SANDBOX_ENV_ARGS=()
if [ "$SANDBOX" = "1" ]; then
  for _tool in claude codex; do
    SANDBOX_ENV_ARGS+=(--env "BASH_FUNC_${_tool}%%=() { exec $SCRIPT_DIR/scripts/agent-sandbox.sh \"\$PWD\" -- $_tool \"\$@\"; }")
  done
fi
# Configuration precedence, for every value below: environment variable wins,
# then settings.json in the state folder (written by the launcher's setup
# questions), then a built-in fallback that matches the daemon's original
# behaviour. The environment path exists so the service can be driven directly.
SETTINGS_FILE="$STATE_DIR/settings.json"

settings_get() { # <jq path, e.g. .laneCap> -> value or empty
  [ -f "$SETTINGS_FILE" ] || return 0
  jq -r "$1 // empty" "$SETTINGS_FILE" 2>/dev/null
}

int_or() { # <value> <fallback> -> the value if it is a whole number, else the fallback
  case "${1:-}" in
    '' | *[!0-9]*) echo "$2" ;;
    *) echo "$1" ;;
  esac
}

LANE_CAP="$(int_or "${FLEET_LANE_CAP:-$(settings_get '.laneCap')}" 5)"
SPAWN_BUDGET="$(int_or "${FLEET_SPAWN_BUDGET:-$(settings_get '.spawnBudget')}" 30)"
# The last fifth of the nightly spawn budget is set aside for recovery work
# (fix agents, a respawned reviewer, a conflict-resolver) so a busy night can
# never spend the whole budget on fresh work and have nothing left to rescue
# a stuck lane with.
RECOVERY_RESERVE=$((SPAWN_BUDGET / 5))
UNRESERVED_BUDGET=$((SPAWN_BUDGET - RECOVERY_RESERVE))
# Overnight rule (Ben, 2026-08-24): while the fleet runs unattended it only
# starts work on issues that already have a written plan; the night is for
# building, not for inventing scope. The window is local-time whole hours
# [start, end); setting start equal to end disables the rule.
OVERNIGHT_START_HOUR="$(int_or "${FLEET_OVERNIGHT_START_HOUR:-$(settings_get '.overnightStartHour')}" 23)"
OVERNIGHT_END_HOUR="$(int_or "${FLEET_OVERNIGHT_END_HOUR:-$(settings_get '.overnightEndHour')}" 8)"
STALE_SECONDS=$((30 * 60))
REVIEW_STALE_SECONDS=$((15 * 60))
# An idle agent whose worktree still has a live process in it (a test run
# launched in the background) is held, not counted done, for at most this
# long -- reaping the pane kills the sandbox and the still-running test with
# it (seen live 2026-08-25: two rounds on lane 1987 and one on 1982 died
# this way). After the cap the normal done-handling proceeds, loudly.
IDLE_HOLD_CAP_SECONDS=$((45 * 60))
# A lane stuck "merging" this long, with the pull request still open, gets
# one merge-state re-check (Unit 5). A lane whose checks have been pending
# this long gets one re-run request, then this long again before parking.
MERGING_DEADLINE_SECONDS=$((45 * 60))
TEARDOWN_MAX_ATTEMPTS=5
CHECKS_PENDING_DEADLINE_SECONDS=$((90 * 60))
# Every judgment shell-out goes through one command so no provider or model
# name is baked into the fleet. The default runs the local Claude CLI on
# whatever model it is configured to use; override to point at another
# provider. Word-splitting here is deliberate -- the value is a command.
JUDGE_CMD="${FLEET_JUDGE_CMD:-$(settings_get '.judgeCmd')}"
JUDGE_CMD="${JUDGE_CMD:-claude -p}"

# A judge command that will not even run (bad PATH under the service after a
# reboot, an expired login) is a fleet-level problem, not a strange answer
# from any one lane. Logged once per tick, not once per lane -- the same
# broken command would otherwise write the same alarm dozens of times.
JUDGE_COMMAND_ALARM_LOGGED=0
judge_command_failed_alarm() {
  [ "$JUDGE_COMMAND_ALARM_LOGGED" = "1" ] && return 0
  JUDGE_COMMAND_ALARM_LOGGED=1
  fctl log fleet "ALARM: the judge command could not run at all (check its login and that it is on PATH); triage and parked-lane decisions are stuck until this is fixed, and will retry next tick"
}

tier_model() { # <tier> -> model for this kind of work, or empty for "CLI default"
  if [ -n "${FLEET_BUILD_MODEL:-}" ]; then echo "$FLEET_BUILD_MODEL"; return; fi
  settings_get ".buildModels.\"$1\".model"
}

tier_effort() { # <tier> -> effort level, or empty for "do not pass one"
  if [ -n "${FLEET_BUILD_EFFORT:-}" ]; then echo "$FLEET_BUILD_EFFORT"; return; fi
  # A model pinned by environment does not inherit the settings file's effort:
  # that effort was chosen for whatever model the file names, and pairing it
  # with a hand-pinned model silently misconfigures the spawn. Pin both or
  # neither; pinning only the model falls back to the CLI's own default.
  if [ -n "${FLEET_BUILD_MODEL:-}" ]; then return; fi
  settings_get ".buildModels.\"$1\".effort"
}

tier_tool() { # <tier> -> which agent program runs this kind of work
  if [ -n "${FLEET_BUILD_TOOL:-}" ]; then echo "$FLEET_BUILD_TOOL"; return; fi
  local tool
  tool="$(settings_get ".buildModels.\"$1\".tool")"
  # Falling back to the local Claude CLI keeps a settings file written before
  # tools were configurable working exactly as it did.
  echo "${tool:-claude}"
}

# Each agent program spells the same two ideas -- which model, how hard to think
# -- with its own flags, and needs its own flag to run unattended. A program we
# do not know gets the model on a --model flag and nothing else, which is the
# most common spelling.
agent_launch_args() { # <tool> <model> <effort> -> one argument per line
  local tool="$1" model="$2" effort="$3"
  case "$tool" in
    claude)
      [ -n "$model" ] && printf '%s\n%s\n' --model "$model"
      [ -n "$effort" ] && printf '%s\n%s\n' --effort "$effort"
      printf '%s\n%s\n' --permission-mode bypassPermissions
      ;;
    codex)
      [ -n "$model" ] && printf '%s\n%s\n' -m "$model"
      [ -n "$effort" ] && printf '%s\n%s\n' -c "model_reasoning_effort=$effort"
      printf '%s\n%s\n%s\n%s\n' -s danger-full-access -a never
      ;;
    *)
      [ -n "$model" ] && printf '%s\n%s\n' --model "$model"
      ;;
  esac
  return 0
}

NOW_EPOCH="$(date +%s)"

# --- rails -------------------------------------------------------------------

[ -f "$STATE_DIR/STOP" ] && exit 0
[ -d "$TASKS_DIR" ] || exit 0
cd "$REPO_ROOT" || exit 1
mkdir -p "$BRIEFS_DIR"

# fleetctl is the only writer of lane records. Prefer a fleetctl on PATH (tests
# stub one), otherwise run the real CLI from this repo.
if command -v fleetctl >/dev/null 2>&1; then
  FLEETCTL=(fleetctl)
else
  FLEETCTL=(node "$SCRIPT_DIR/fleetctl.mjs")
fi

# Per-issue summary of log.jsonl, built by one full pass at the start of the
# main loop (log_map_build below) and kept current by log_map_note whenever
# this script itself writes a live log line. The per-lane helpers read these
# instead of re-scanning the whole log file on every call -- that rescan
# happened 30-60 times per tick and dominated tick wall time.
#   LOGMAP_TS       last timestamp of any line for the issue
#   LOGMAP_MSG      last .msg of a line whose .issue field is the issue
#                   (what log_if_new compares against)
#   LOGMAP_RELAY_RESPAWNS / LOGMAP_RESTARTS / LOGMAP_REVIEWER_RESTARTS
#                   counts of the three grep'd message prefixes
#   LOGMAP_CI_RED_LAST  full text of the last "ci-red: failing checks:" line
declare -A LOGMAP_TS=() LOGMAP_MSG=() LOGMAP_RELAY_RESPAWNS=() \
  LOGMAP_RESTARTS=() LOGMAP_REVIEWER_RESTARTS=() LOGMAP_CI_RED_LAST=()

log_map_note() { # <issue> <msg> -> keep the map current after a live log write
  local k="$1" m="$2"
  LOGMAP_TS["$k"]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOGMAP_MSG["$k"]="$m"
  case "$m" in
    "relay: respawned"*) LOGMAP_RELAY_RESPAWNS["$k"]=$(( ${LOGMAP_RELAY_RESPAWNS["$k"]:-0} + 1 )) ;;
    "restart:"*) LOGMAP_RESTARTS["$k"]=$(( ${LOGMAP_RESTARTS["$k"]:-0} + 1 )) ;;
    "reviewer-restart:"*) LOGMAP_REVIEWER_RESTARTS["$k"]=$(( ${LOGMAP_REVIEWER_RESTARTS["$k"]:-0} + 1 )) ;;
    "ci-red: failing checks:"*) LOGMAP_CI_RED_LAST["$k"]="$m" ;;
  esac
}

# Record writes. In dry-run these print instead of executing.
fctl() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: fleetctl $*"
  else
    # A rejected write must never pass silently: the record store refuses the
    # whole command if any one field is unknown, and losing a status stamp
    # quietly is how lane 1889 kept reading "waiting on Ben" after its
    # re-slice (2026-08-25). Log the failure where the viewer can see it.
    if ! "${FLEETCTL[@]}" "$@" 2>>"$STATE_DIR/fleetctl-errors.log"; then
      "${FLEETCTL[@]}" log fleet "ALARM: record write failed and was dropped: fleetctl $*" \
        2>>"$STATE_DIR/fleetctl-errors.log" || true
      return 1
    fi
    if [ "${1:-}" = "log" ] && [ $# -ge 3 ]; then
      log_map_note "$2" "$3"
    fi
  fi
}

# Externally-visible actions (anything that changes the world outside the state
# dir). In dry-run these print instead of executing.
act() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

iso_to_epoch() {
  date -d "$1" +%s 2>/dev/null || echo 0
}

# Never run mid-edit code: if this tooling's own checkout has modified
# TRACKED files, someone is editing the daemon right now, and a half-finished
# edit must not drive any lane. One fleet-level alarm, then stop before
# touching anything. Untracked files (notes, scratch) do not block.
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | grep -q '^[^?]'; then
    fctl log fleet "fleet code has uncommitted edits, tick skipped (quiet guard: not an alarm, resumes on commit)"
    exit 0
  fi
fi

# Creates a lane's worktree, capturing git's own error text. A leftover
# directory from a prior run is a realistic cause, and it can fail every
# minute all night; two failures park the lane with the git error as the
# reason instead of retrying forever (box-wide two-identical-failures rule).
try_create_worktree() { # <issue> <record-json> <git worktree add args...> -> 0 ok, 1 failed (parked or will retry)
  local issue="$1" record="$2"; shift 2
  local err_file err attempts
  if [ "$DRY" = "1" ]; then
    echo "DRY: git -C $REPO_ROOT worktree add $*"
    return 0
  fi
  err_file="$(mktemp)"
  if git -C "$REPO_ROOT" worktree add "$@" >"$err_file" 2>&1; then
    rm -f "$err_file"
    return 0
  fi
  err="$(tr '\n' ' ' <"$err_file" | sed -E 's/[[:space:]]+/ /g; s/ $//')"
  rm -f "$err_file"
  attempts=$(($(jq -r '.worktree_attempts // 0' <<<"$record") + 1))
  if [ "$attempts" -ge 2 ]; then
    fctl set "$issue" status=blocked "blocked_reason=could not create the worktree: ${err:-<no error captured>}" "worktree_attempts=$attempts"
    fctl log "$issue" "worktree creation failed twice in a row; parked with the git error as the reason"
  else
    fctl set "$issue" "worktree_attempts=$attempts"
    fctl log "$issue" "worktree creation failed (attempt $attempts of 2): ${err:-<no error captured>}; will retry next tick"
  fi
  return 1
}

# Spawn budget window starts at the most recent 18:00 local time.
budget_cutoff_epoch() {
  local day
  if [ "$(date +%H)" -ge 18 ]; then day="$(date +%F)"; else day="$(date -d yesterday +%F)"; fi
  date -d "$day 18:00" +%s
}

# A small counter file, reset whenever the nightly budget window rolls over,
# replaces scanning the whole log on every tick -- that scan got slower every
# night as the log grew. The file holds two numbers: the window's start time
# and how many spawns have happened since.
SPAWN_COUNT_FILE="$STATE_DIR/.spawn-count"

count_spawns_tonight() {
  local cutoff stored_cutoff stored_count
  cutoff="$(budget_cutoff_epoch)"
  stored_cutoff=0
  stored_count=0
  if [ -f "$SPAWN_COUNT_FILE" ]; then
    read -r stored_cutoff stored_count < "$SPAWN_COUNT_FILE" 2>/dev/null || true
  fi
  case "$stored_cutoff" in '' | *[!0-9]*) stored_cutoff=0 ;; esac
  case "$stored_count" in '' | *[!0-9]*) stored_count=0 ;; esac
  if [ "$stored_cutoff" != "$cutoff" ]; then
    # A new night has started (or the file was never written): start counting fresh.
    stored_count=0
    echo "$cutoff $stored_count" > "$SPAWN_COUNT_FILE"
  fi
  echo "$stored_count"
}

SPAWNS_TONIGHT="$(count_spawns_tonight)"

budget_available() {
  [ "$SPAWNS_TONIGHT" -lt "$UNRESERVED_BUDGET" ]
}

# Recovery spawns (a fix agent, a respawned reviewer, a conflict-resolver) may
# dip into the reserved fifth of the budget once the unreserved part is gone.
budget_available_recovery() {
  [ "$SPAWNS_TONIGHT" -lt "$SPAWN_BUDGET" ]
}

# Recovery work found the whole budget gone (reserve included): park at once
# with a plain reason instead of waiting silently for room that never comes.
park_budget_exhausted() { # <issue>
  fctl set "$1" status=blocked "blocked_reason=spawn budget exhausted"
  fctl log "$1" "recovery spawn needed but the spawn budget is exhausted; parked"
}

note_spawn() {
  SPAWNS_TONIGHT=$((SPAWNS_TONIGHT + 1))
  echo "$(budget_cutoff_epoch) $SPAWNS_TONIGHT" > "$SPAWN_COUNT_FILE"
}

# Deputy switch. ON by default (Ben's standing rule, 2026-08-24: the fleet
# handles everything itself and never pauses for him; the judgment model
# holds his decision authority). Turned off only by an explicit
# deputyEnabled=false in settings.json or FLEET_DEPUTY_ENABLED=false in the
# environment. The launcher shows this state on screen at all times; the
# hard floor below is unaffected by it.
DEPUTY_ACTIVE=1
# settings_get cannot see an explicit false (its jq default-idiom folds false
# into "unset"), and false is exactly the value that matters here -- so this
# one read asks jq for the raw value.
deputy_enabled="${FLEET_DEPUTY_ENABLED:-}"
if [ -z "$deputy_enabled" ] && [ -f "$SETTINGS_FILE" ]; then
  deputy_enabled="$(jq -r 'if .deputyEnabled == null then "" else (.deputyEnabled | tostring) end' "$SETTINGS_FILE" 2>/dev/null)"
fi
[ "$deputy_enabled" = "false" ] && DEPUTY_ACTIVE=0

# --- shared helpers ------------------------------------------------------------

# Memory floor (spec: 4 GB). The fleet degrades instead of pushing the box
# into swap at 4am: below the floor no new agent starts, and the tick says
# so and carries on. An unreadable source fails open -- a box where free
# memory cannot be read should not silently stop the fleet.
MEMINFO_SOURCE="${FLEET_MEMINFO:-/proc/meminfo}"
MEMORY_FLOOR_MB="$(int_or "${FLEET_MEMORY_FLOOR_MB:-$(settings_get '.memoryFloorMb')}" 4096)"

memory_ok() {
  local kb
  [ "$MEMORY_FLOOR_MB" -gt 0 ] || return 0
  kb="$(awk '/^MemAvailable:/ {print $2}' "$MEMINFO_SOURCE" 2>/dev/null)"
  case "$kb" in '' | *[!0-9]*) return 0 ;; esac
  [ $((kb / 1024)) -ge "$MEMORY_FLOOR_MB" ]
}

refuse_spawn_low_memory() { # <issue>
  fctl log "$1" "not starting an agent: free memory is below the $MEMORY_FLOOR_MB MB floor; will try again next tick"
}

# The memory floor is also worth a fleet-level warning even on a tick where
# nothing is trying to spawn -- Ben should see the box is tight on memory
# before it costs a lane, not only once a spawn is refused.
memory_low_warning() {
  if ! memory_ok; then
    fctl log fleet "WARNING: free memory is below the $MEMORY_FLOOR_MB MB floor; no new agent will start until it recovers"
  fi
}

lane_log_tail() { # <issue> [n]
  local issue="$1" n="${2:-20}"
  [ -f "$LOG_FILE" ] || return 0
  jq -c --argjson n "$issue" 'select((.issue // .task // -1) == $n)' "$LOG_FILE" 2>/dev/null | tail -n "$n"
}

# The one full read of log.jsonl per tick. Messages travel base64-encoded so
# a message containing a tab or newline cannot shear the row. lane_log_tail
# above keeps its own full pass: it feeds judge and deputy prompts, which run
# rarely. Malformed log lines are skipped (fromjson?), matching the old
# helpers' tolerance.
log_map_build() {
  [ -f "$LOG_FILE" ] || return 0
  # The row delimiter is "|", not a tab: tab is IFS whitespace, so adjacent
  # tabs collapse and an empty field (a lane with no ci-red line yet) would
  # shift every later column. "|" never appears in the key, an ISO timestamp,
  # a count, or base64.
  local k ts relay restart rrestart cired_b64 mi_b64
  while IFS='|' read -r k ts relay restart rrestart cired_b64 mi_b64; do
    [ -n "$k" ] || continue
    LOGMAP_TS["$k"]="$ts"
    LOGMAP_RELAY_RESPAWNS["$k"]="$relay"
    LOGMAP_RESTARTS["$k"]="$restart"
    LOGMAP_REVIEWER_RESTARTS["$k"]="$rrestart"
    LOGMAP_CI_RED_LAST["$k"]="$(printf '%s' "$cired_b64" | base64 -d 2>/dev/null)"
    LOGMAP_MSG["$k"]="$(printf '%s' "$mi_b64" | base64 -d 2>/dev/null)"
  done < <(jq -Rrn '
    reduce (inputs | fromjson? // empty) as $l ({};
      (($l.issue // $l.task // -1) | tostring) as $k
      | ($l.msg // $l.message // "") as $m
      | .[$k] = ((.[$k] // {ts:"", relay:0, restart:0, rrestart:0, cired:""})
          | .ts = ($l.ts // $l.timestamp // "")
          | (if $m | startswith("relay: respawned") then .relay += 1 else . end)
          | (if $m | startswith("restart:") then .restart += 1 else . end)
          | (if $m | startswith("reviewer-restart:") then .rrestart += 1 else . end)
          | (if $m | startswith("ci-red: failing checks:") then .cired = $m else . end))
      | (if ($l | has("issue")) and ($l.issue != null) then
           (($l.issue | tostring) as $k2
            | .[$k2] = ((.[$k2] // {ts:"", relay:0, restart:0, rrestart:0, cired:""})
                | .mi = ($l.msg // "")))
         else . end))
    | to_entries[]
    | [.key, .value.ts, (.value.relay | tostring), (.value.restart | tostring),
       (.value.rrestart | tostring), (.value.cired | @base64),
       ((.value.mi // "") | @base64)]
    | join("|")' "$LOG_FILE" 2>/dev/null)
}

herdr_agent_names() {
  # Only agents still running count. A finished agent whose pane is still
  # open reports agent_status "done" -- counting it as live froze a lane
  # for real on the first night (the build agent finished, its pane
  # lingered, and the reviewer was never sent in).
  herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]? | select((.agent_status // "") != "done") | .name // empty' 2>/dev/null
}

# Whole-token match against the fleet's own agent-naming patterns for one
# issue (fleet-lane-N, fleet-qa-N, fleet-fix-N, fleet-rescue-N, and their
# round suffixes like -r2 or -r2-retry) -- never a bare substring, so issue
# 189 is never starved by an agent actually working on issue 1894.
issue_agent_name_re() { # <issue> -> a grep -E pattern
  printf '^fleet-(lane|qa|fix|rescue)-%s(-(ci|qa|merge))?(-r[0-9]+)?(-retry|-chunked)?$' "$1"
}

issue_agent_live() { # <issue> -> 0 if any of the fleet's own agents for this issue is live
  herdr_agent_names | grep -Eq -- "$(issue_agent_name_re "$1")"
}

# The terminal manager's done/idle flag proved unstable live (2026-08-25:
# three finished agents read "done" one minute and "idle" the next after a
# nudge woke them). So once the state machine says a stage has concluded --
# the finishing agent's last act is writing the status that says so -- the
# only honest question left before a spawn is a name collision: does a pane
# already hold the exact name about to be used? Any status counts, because
# the terminal manager refuses to start a second agent under a taken name.
pane_name_exists() { # <agent name> -> 0 if any pane holds this exact name
  herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]?.name // empty' 2>/dev/null \
    | grep -qxF -- "$1"
}

herdr_agent_status() { # <agent name> -> its reported status, empty if absent
  herdr agent list 2>/dev/null \
    | jq -r --arg n "$1" '.result.agents[]? | select(.name == $n) | .agent_status // empty' 2>/dev/null \
    | head -n1
}

# 0 when neither the lane record nor its log has moved within <seconds>. The
# dead-man question behind both the idle-corpse check and the stillness alarm:
# silence plus an agent that is not working means stuck, whatever the cause.
lane_silent_for() { # <issue> <record-json> <seconds>
  local issue="$1" record="$2" window="$3" updated last_ts age
  updated="$(jq -r '.updated_at // empty' <<<"$record")"
  if [ -n "$updated" ]; then
    age=$((NOW_EPOCH - $(iso_to_epoch "$updated")))
    [ "$age" -ge "$window" ] || return 1
  fi
  last_ts="${LOGMAP_TS[$issue]:-}"
  if [ -n "$last_ts" ]; then
    age=$((NOW_EPOCH - $(iso_to_epoch "$last_ts")))
    [ "$age" -ge "$window" ] || return 1
  fi
  return 0
}

# Does any live process still have its current directory inside this
# worktree? readlink across /proc is cheap (one pass, no forks per pid
# beyond the comm/PPid reads). The daemon's own children never match -- the
# tick runs from REPO_ROOT -- but $$ is skipped anyway. An open agent
# session is furniture, not work: on this box the chain is herdr (agent
# manager) -> bwrap (sandbox wrapper, absent when the sandbox is off) ->
# claude (the session) -> whatever the agent actually ran. So the sandbox
# wrapper itself and the session process (claude directly under bwrap or
# herdr) are skipped -- an agent idle at its prompt must not hold its own
# lane -- as is a shell whose parent is a tmux server. Everything else
# counts: a bash/node/test child of the session is exactly the background
# run this guard exists to protect.
worktree_has_live_process() { # <worktree> -> 0 when something is still running in it
  local wt="$1" entry pid cwd comm ppid pcomm
  wt="$(readlink -f "$wt" 2>/dev/null)"
  [ -n "$wt" ] || return 1
  for entry in /proc/[0-9]*; do
    pid="${entry#/proc/}"
    [ "$pid" = "$$" ] && continue
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    case "$cwd" in "$wt" | "$wt"/*) ;; *) continue ;; esac
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
    case "$comm" in bwrap) continue ;; esac
    ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)"
    pcomm=""
    [ -n "$ppid" ] && pcomm="$(cat "/proc/$ppid/comm" 2>/dev/null)"
    case "$comm:$pcomm" in claude:bwrap | claude:herdr) continue ;; esac
    case "$pcomm" in tmux*) continue ;; esac
    return 0
  done
  return 1
}

# The idle-corpse guard: an agent can look finished (idle at its prompt, or
# gone from the live list) while a test run it launched in the background is
# still going in its worktree. Counting it done then reaps the pane, and the
# sandbox death kills the test mid-run. So before an idle agent is counted
# done, hold the lane while anything still runs in its worktree -- but never
# forever: after IDLE_HOLD_CAP_SECONDS of consecutive holds (idle_hold_since
# on the record marks the first one) the hold gives up loudly and the normal
# done-handling proceeds.
hold_for_worktree_process() { # <issue> <record> -> 0 hold this tick (caller returns), 1 proceed
  local issue="$1" record="$2" worktree hold_since
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  if ! worktree_has_live_process "$worktree"; then
    # Nothing running (any earlier hold is over): clear the marker and go on.
    if [ -n "$(jq -r '.idle_hold_since // empty' <<<"$record")" ]; then
      fctl set "$issue" idle_hold_since=
    fi
    return 1
  fi
  hold_since="$(jq -r '.idle_hold_since // 0' <<<"$record")"
  case "$hold_since" in '' | *[!0-9]*) hold_since=0 ;; esac
  if [ "$hold_since" -gt 0 ]; then
    if [ $((NOW_EPOCH - hold_since)) -ge "$IDLE_HOLD_CAP_SECONDS" ]; then
      fctl log "$issue" "ALARM: the agent has looked idle for 45 minutes while a process kept running in its worktree; giving up the hold and counting the agent done anyway"
      fctl set "$issue" idle_hold_since=
      return 1
    fi
  else
    fctl set "$issue" "idle_hold_since=$NOW_EPOCH"
  fi
  log_if_new "$issue" "agent looks idle but a process is still running in its worktree; holding"
  return 0
}

close_issue_leftover_agents() { # <issue> -> 0 no agent held the name, 1 a working agent holds it, 2 leftovers closed
  # Every registered agent counts here, including ones whose status reads
  # "done": a finished agent still holds its name, and herdr refuses to
  # start a new agent under it (seen live on lane 1951, 2026-08-25: the
  # old closer skipped done agents and dispatch failed every tick for an
  # hour). Only a genuinely working agent is left alone.
  local issue="$1" re name astatus working=0 closed=0
  re="$(issue_agent_name_re "$issue")"
  while IFS=$'\t' read -r name astatus; do
    [ -n "$name" ] || continue
    grep -Eq -- "$re" <<<"$name" || continue
    if [ "$astatus" = "working" ]; then
      working=1
      continue
    fi
    fctl log "$issue" "closed the leftover agent window $name (status ${astatus:-unknown}) so the lane can dispatch again"
    close_named_pane "$name"
    closed=1
  done < <(herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]? | [.name // "", .agent_status // ""] | @tsv' 2>/dev/null)
  [ "$working" = "1" ] && return 1
  [ "$closed" = "1" ] && return 2
  return 0
}

# Tolerant answer parsing, shared by judgment_call and deputy_call: the reply
# counts only if its first line contains exactly one of the allowed words
# anywhere in it. Two allowed words on the same line is treated the same as
# none -- guessing between them is worse than asking again.
parse_ruling() { # <first line of the reply> <allowed word> [allowed word...]
  local raw="$1"; shift
  local upper="${raw^^}" word found=""
  local count=0
  for word in "$@"; do
    if grep -qw "$word" <<<"$upper"; then
      found="$word"
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] && printf '%s' "$found"
}

# One-shot judgment call. Prompt is plain English: the question, the record, the
# last 20 log lines for this lane, and the exact answer format. The reply's
# first line must contain exactly one of the allowed words; anything else is
# treated as no ruling. Dry-run prints the call and returns no ruling.
judgment_call() { # <issue> <record-json> <options e.g. 'RESTART or PARK'> <question>
  local issue="$1" record="$2" options="$3" question="$4"
  local prompt raw out_file
  RULING=""
  RAW_ANSWER=""
  JUDGE_FAILED=0
  prompt="$question

Answer with a SINGLE first line containing exactly one word: $options. You may explain after the first line, but only the first line is read.

Lane record:
$record

Last 20 log lines for this lane:
$(lane_log_tail "$issue")"
  if [ "$DRY" = "1" ]; then
    echo "DRY: $JUDGE_CMD [judgment for lane $issue: $question]"
    echo ""
    return 0
  fi
  out_file="$(mktemp)"
  # shellcheck disable=SC2086 # JUDGE_CMD is a command, splitting is intended
  if ! $JUDGE_CMD "$prompt" >"$out_file" 2>&1; then
    rm -f "$out_file"
    JUDGE_FAILED=1
    judge_command_failed_alarm
    return 1
  fi
  raw="$(head -n1 "$out_file" | tr -d '\r')"
  rm -f "$out_file"
  RAW_ANSWER="$raw"
  RULING="$(parse_ruling "$raw" RESTART PARK)"
  fctl log "$issue" "judgment question: $question"
  fctl log "$issue" "judgment ruling: ${RULING:-<no answer>}"
}

# Ask the judgment model to draft a follow-up issue for a lane that relayed
# itself out: first line of the reply is the new issue's title, the rest is
# its body. Sets RESLICE_TITLE / RESLICE_BODY. Dry-run prints the call and
# reports failure so the caller falls back to the plain park.
reslice_draft() { # <issue> <record-json> -> 0 with RESLICE_TITLE/RESLICE_BODY, or 1
  local issue="$1" record="$2"
  local prompt out_file title
  RESLICE_TITLE=""
  RESLICE_BODY=""
  if [ "$DRY" = "1" ]; then
    echo "DRY: $JUDGE_CMD [re-slice draft for lane $issue]"
    return 1
  fi
  prompt="A fleet build lane for GitHub issue #$issue relayed twice, which means the task was sliced too big to finish in one agent session. Write a follow-up issue that captures ONLY the remaining work, so a fresh agent can finish it in a single session.

Your reply's FIRST line is the follow-up issue's title: plain and specific, no prefix.
Every line after the first is the issue body, in plain English a human skims: what already works (name the pull request if one is open), what still fails or remains, and what finishing looks like. Carry over any guardrails the original issue states. No jargon, no invented terms, plain ASCII punctuation.

Lane record:
$record

Last 20 log lines for this lane:
$(lane_log_tail "$issue")"
  out_file="$(mktemp)"
  # shellcheck disable=SC2086 # JUDGE_CMD is a command, splitting is intended
  if ! $JUDGE_CMD "$prompt" >"$out_file" 2>&1; then
    rm -f "$out_file"
    judge_command_failed_alarm
    return 1
  fi
  title="$(head -n1 "$out_file" | tr -d '\r')"
  RESLICE_BODY="$(tail -n +2 "$out_file" | sed -e '/./,$!d')"
  rm -f "$out_file"
  RESLICE_TITLE="$title"
  if [ -z "$RESLICE_TITLE" ] || [ -z "$RESLICE_BODY" ]; then
    fctl log "$issue" "re-slice draft came back empty; cannot re-slice automatically"
    return 1
  fi
  return 0
}

# Adds a freshly cut issue to the project board and moves it to Ready.
# Best-effort: a warning on any miss, never a rollback.
board_add_ready() { # <issue-number> <issue-url>
  local num="$1" url="$2" item_id project_id fields status_field_id option_id
  item_id="$(gh project item-add "$FLEET_PROJECT_NUMBER" --owner "$FLEET_PROJECT_OWNER" \
    --url "$url" --format json --jq '.id' 2>/dev/null)"
  if [ -n "$item_id" ]; then
    project_id="$(gh project view "$FLEET_PROJECT_NUMBER" --owner "$FLEET_PROJECT_OWNER" --format json --jq '.id' 2>/dev/null)"
    fields="$(gh project field-list "$FLEET_PROJECT_NUMBER" --owner "$FLEET_PROJECT_OWNER" --format json 2>/dev/null)"
    status_field_id="$(jq -r '.fields[]? | select((.name|ascii_downcase)=="status") | .id // empty' <<<"$fields" | head -n1)"
    option_id="$(jq -r '.fields[]? | select((.name|ascii_downcase)=="status") | .options[]? | select((.name|ascii_downcase)=="ready") | .id // empty' <<<"$fields" | head -n1)"
    if [ -n "$project_id" ] && [ -n "$status_field_id" ] && [ -n "$option_id" ] \
      && gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$status_field_id" --single-select-option-id "$option_id" >/dev/null 2>&1; then
      fctl log "$num" "put issue #$num on the project board in Ready"
    else
      fctl log "$num" "warning: issue #$num was added to the board but could not be moved to Ready"
    fi
  else
    fctl log "$num" "warning: could not add issue #$num to the project board"
  fi
}

# A lane that relayed twice re-slices itself: a follow-up issue is drafted,
# created with the run label, put on the board in Ready, and the old lane is
# parked with a pointer -- no phone round-trip (Ben's call, 2026-08-24: he
# would only ever reply "reslice" anyway). Returns 1 when it cannot (the
# caller parks and asks), and 2 when slicing again is forbidden -- the
# caller resumes the lane instead (Ben's standing answer, 2026-08-25: he
# would only ever reply "resume" anyway).
auto_reslice() { # <issue> <record-json> -> 0 re-sliced and parked, 1 fall back
  local issue="$1" record="$2"
  local parent_body repo spec tier pr follow_url follow_num body marker
  local err_file item_id project_id fields status_field_id option_id

  # A lane already re-sliced once has its follow-up issue somewhere; cutting
  # another duplicates it. This happened live on the first night: a hand
  # re-slice into one issue, then a model resume, then an automatic re-slice
  # into a second, duplicate issue. Refuse; the caller resumes the lane.
  if jq -e '((.blocked_reason // "") | test("re-sliced")) or (.resliced_to != null)' <<<"$record" >/dev/null 2>&1; then
    fctl log "$issue" "not slicing again: this lane was already re-sliced once"
    return 2
  fi

  # A re-slice of a re-slice means the slicing itself is failing: stop the
  # chain. The caller resumes the lane instead of generating issues forever.
  marker="Re-sliced by the fleet daemon from #"
  parent_body="$(jq -r --arg n "$issue" \
    '.items[]? | select((.content.number|tostring) == $n) | .content.body // ""' \
    "$STATE_DIR/$BOARD_FULL_FILE" 2>/dev/null | head -c 4000)"
  if grep -qF "$marker" <<<"$parent_body"; then
    fctl log "$issue" "this lane is already a re-slice; not slicing again"
    return 2
  fi

  spec="$(jq -r '.spec // ""' <<<"$record")"
  repo="$(sed -nE 's|^https://github.com/([^/]+/[^/]+)/issues/[0-9]+$|\1|p' <<<"$spec")"
  if [ -z "$repo" ]; then
    fctl log "$issue" "cannot re-slice automatically: the lane's spec is not an issue link, so the repo is unknown"
    return 1
  fi
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  pr="$(jq -r '.pr // empty' <<<"$record")"

  reslice_draft "$issue" "$record" || return 1

  body="$marker$issue.

$RESLICE_BODY"
  err_file="$(mktemp)"
  follow_url="$(gh issue create --repo "$repo" --title "$RESLICE_TITLE" \
    --label "$FLEET_RUN_LABEL" --body "$body" 2>"$err_file" | tail -n1)"
  if [ -z "$follow_url" ]; then
    # The one likely non-transient cause is the run label not existing in
    # this repo; an unlabeled issue Ben must label is worse than asking him
    # directly, so any create failure falls back to the plain park.
    fctl log "$issue" "creating the follow-up issue failed: $(head -c 200 "$err_file" 2>/dev/null | tr '\n' ' '); falling back to asking Ben"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  follow_num="$(sed -nE 's|.*/issues/([0-9]+)$|\1|p' <<<"$follow_url")"
  if [ -z "$follow_num" ]; then
    fctl log "$issue" "the follow-up issue was created but its number could not be read from $follow_url; falling back to asking Ben"
    return 1
  fi

  # The follow-up becomes a queued lane at once -- it must not wait on the
  # next board read. Intake never touches existing records, so this record
  # simply pre-empts the one intake would have made.
  fctl add "$follow_num" "spec=$follow_url" "tier=$tier"
  fctl set "$follow_num" "title=$RESLICE_TITLE"
  fctl log "$follow_num" "re-sliced from issue #$issue; queued fresh, tier $tier"

  # Board and cross-links are best-effort: a warning, never a rollback.
  gh issue comment "$issue" --repo "$repo" \
    --body "Re-sliced by the fleet daemon: this lane relayed twice, so the remaining work moved to #$follow_num.${pr:+ PR #$pr stays open for review.}" \
    >/dev/null 2>&1 || fctl log "$issue" "warning: could not leave the re-slice comment on issue #$issue"
  board_add_ready "$follow_num" "$follow_url"

  fctl set "$issue" status=blocked \
    "blocked_reason=re-sliced automatically: remaining work is issue #$follow_num${pr:+; PR #$pr stays open for review}" \
    "resliced_to=$follow_num"
  fctl log "$issue" "relayed out; re-sliced automatically into issue #$follow_num"
  return 0
}

# When a merged lane was cut out of a bigger parent issue ("part N of #X"),
# the split machinery must eventually look back at the parent: either more
# work remains and the next part gets cut, or everything is covered and the
# parent closes. The judge reads the parent issue and the merged part and
# decides. Best-effort by design: any failure logs a warning and leaves the
# parent parked exactly as it was, where the morning board shows it -- never
# a retry loop, never a rollback, and a parent that stays parked is harmless.
revisit_parent_after_merge() { # <merged-child-issue> -> always 0
  local child="$1"
  local parent="" f record spec repo tier parent_body prompt out_file first rest
  local body follow_url follow_num err_file line
  local existing_json existing_list existing_nums existing_num existing_section

  # The parent is the record whose re-slice pointer names this merged lane.
  for f in "$TASKS_DIR"/*.json; do
    [ -f "$f" ] || continue
    if jq -e --argjson c "$child" '.resliced_to == $c' "$f" >/dev/null 2>&1; then
      parent="$(jq -r '.issue' "$f")"
      record="$(cat "$f")"
      break
    fi
  done
  [ -n "$parent" ] || return 0
  [ "$(jq -r '.status // ""' <<<"$record")" = "done" ] && return 0

  if [ "$DRY" = "1" ]; then
    echo "DRY: $JUDGE_CMD [parent revisit for issue $parent after lane $child merged]"
    return 0
  fi

  spec="$(jq -r '.spec // ""' <<<"$record")"
  repo="$(sed -nE 's|^https://github.com/([^/]+/[^/]+)/issues/[0-9]+$|\1|p' <<<"$spec")"
  if [ -z "$repo" ]; then
    fctl log "$parent" "warning: cannot revisit parent issue #$parent after part #$child merged: its spec is not an issue link, so the repo is unknown"
    return 0
  fi
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  parent_body="$(gh issue view "$parent" --repo "$repo" --json title,body \
    --jq '.title + "\n\n" + .body' 2>/dev/null | head -c 6000)"

  # Open issues in the same repo that already mention the parent: the next
  # part may already exist (a hand re-slice, an earlier automatic cut), and a
  # judge that never sees them drafts near-duplicates -- seen live 2026-08-26,
  # when the draft for parent #1965 duplicated the pre-existing piece #1970
  # almost word for word. Best-effort: if the lookup fails or finds nothing,
  # the prompt simply carries no list and behaves exactly as before.
  existing_json="$(gh issue list --repo "$repo" --state open --search "#$parent" \
    --json number,title,body --limit 20 2>/dev/null)"
  existing_list=""
  existing_nums=""
  if [ -n "$existing_json" ]; then
    existing_nums="$(jq -r --argjson p "$parent" --argjson c "$child" \
      '.[]? | select(.number != $p and .number != $c) | .number' \
      <<<"$existing_json" 2>/dev/null)"
    existing_list="$(jq -r --argjson p "$parent" --argjson c "$child" \
      '.[]? | select(.number != $p and .number != $c)
        | "#\(.number): \(.title)\n" + ((.body // "") | split("\n") | .[:3] | join("\n"))' \
      <<<"$existing_json" 2>/dev/null)"
  fi
  existing_section=""
  if [ -n "$existing_nums" ]; then
    existing_section="

Before drafting anything, look at these OPEN issues that already mention #$parent (number and title, then the first lines of the body):
$existing_list

If one of those listed issues already covers the next unfinished part, do NOT draft a duplicate. Instead your reply's FIRST line must be exactly: EXISTING #N (where N is that issue's number from the list). Nothing else on that line."
  fi

  prompt="GitHub issue #$parent was split into parts because it was too big for one agent session. The latest part, issue #$child, just merged. Decide what happens to the parent issue next.

If every piece of work the parent asks for is now covered by merged parts, reply with exactly one word on the first line: DONE

Otherwise, draft the NEXT part as a follow-up issue. Your reply's FIRST line is that issue's title: plain and specific, no prefix; keep the \"part N of #$parent\" style if the earlier parts used it. Every line after the first is the issue body, in plain English a human skims: what the earlier parts already delivered, what this part covers, and what finishing looks like. Cover only work the parent asks for that no merged part delivered. Carry over any guardrails the parent states. No jargon, plain ASCII punctuation.$existing_section

Parent issue #$parent (title, then body):
$parent_body

Parent lane record:
$record

Last 20 log lines for the merged part (lane $child):
$(lane_log_tail "$child")"

  out_file="$(mktemp)"
  # shellcheck disable=SC2086 # JUDGE_CMD is a command, splitting is intended
  if ! $JUDGE_CMD "$prompt" >"$out_file" 2>&1; then
    rm -f "$out_file"
    judge_command_failed_alarm
    return 0
  fi
  first="$(head -n1 "$out_file" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  rest="$(tail -n +2 "$out_file" | sed -e '/./,$!d')"
  rm -f "$out_file"

  if [ -z "$first" ]; then
    fctl log "$parent" "warning: the parent-revisit draft for issue #$parent came back empty; leaving the parent as it is"
    return 0
  fi

  if [ "${first^^}" = "DONE" ]; then
    err_file="$(mktemp)"
    if gh issue close "$parent" --repo "$repo" \
      --comment "All parts of this issue are finished and merged; the last one was #$child. Closed by the fleet daemon." \
      >/dev/null 2>"$err_file"; then
      fctl set "$parent" status=done blocked_reason=
      fctl log "$parent" "all parts merged (last: #$child); closed parent issue #$parent and marked its lane done"
    else
      fctl log "$parent" "warning: all parts of issue #$parent look merged but closing it failed: $(head -c 200 "$err_file" 2>/dev/null | tr '\n' ' '); it stays open for the morning board"
    fi
    rm -f "$err_file"
    return 0
  fi

  # The judge was told to put EXISTING on the FIRST line, but live on
  # 2026-08-26 it explained itself on line 1 and put "EXISTING #1971" on
  # line 3; the first-line-only check missed it and drafted a junk issue
  # titled with the explanation. When the first line is not a recognized
  # answer, scan the rest of the reply for the first EXISTING line. Safe to
  # overwrite first: the EXISTING branch below always returns, so a scanned
  # match never leaks into the draft-title path.
  if ! [[ "${first^^}" =~ ^EXISTING[[:space:]]+#?[0-9]+$ ]] && [ -n "$rest" ]; then
    while IFS= read -r line; do
      if [[ "${line^^}" =~ ^[[:space:]]*(EXISTING[[:space:]]+#?[0-9]+)[[:space:]]*$ ]]; then
        first="${BASH_REMATCH[1]}"
        break
      fi
    done <<<"$rest"
  fi

  # The judge picked one of the offered existing follow-ups instead of
  # drafting: promote that issue rather than creating a duplicate. The number
  # must be one actually offered -- an arbitrary number back is never trusted.
  if [[ "${first^^}" =~ ^EXISTING[[:space:]]+#?([0-9]+)$ ]]; then
    existing_num="${BASH_REMATCH[1]}"
    if [ -n "$existing_nums" ] && grep -qx "$existing_num" <<<"$existing_nums"; then
      follow_num="$existing_num"
      follow_url="https://github.com/$repo/issues/$follow_num"
      board_add_ready "$follow_num" "$follow_url"
      fctl set "$parent" \
        "blocked_reason=re-sliced automatically: remaining work is issue #$follow_num" \
        "resliced_to=$follow_num"
      fctl log "$parent" "part #$child merged; the next part already exists as issue #$follow_num, so nothing new was drafted"
      fctl log fleet "parent revisit for issue #$parent reused the existing follow-up issue #$follow_num instead of drafting a duplicate"
    else
      fctl log "$parent" "warning: the parent-revisit answer named issue #$existing_num, which is not one of the open follow-ups it was offered; leaving the parent as it is"
    fi
    return 0
  fi

  if [ -z "$rest" ]; then
    fctl log "$parent" "warning: the parent-revisit draft for issue #$parent had a title but no body; leaving the parent as it is"
    return 0
  fi

  body="Re-sliced by the fleet daemon from #$parent.

$rest"
  err_file="$(mktemp)"
  follow_url="$(gh issue create --repo "$repo" --title "$first" \
    --label "$FLEET_RUN_LABEL" --body "$body" 2>"$err_file" | tail -n1)"
  if [ -z "$follow_url" ]; then
    fctl log "$parent" "warning: creating the next part of issue #$parent failed: $(head -c 200 "$err_file" 2>/dev/null | tr '\n' ' '); the parent stays parked for the morning board"
    rm -f "$err_file"
    return 0
  fi
  rm -f "$err_file"
  follow_num="$(sed -nE 's|.*/issues/([0-9]+)$|\1|p' <<<"$follow_url")"
  if [ -z "$follow_num" ]; then
    fctl log "$parent" "warning: the next part of issue #$parent was created but its number could not be read from $follow_url; the parent stays parked"
    return 0
  fi

  fctl add "$follow_num" "spec=$follow_url" "tier=$tier"
  fctl set "$follow_num" "title=$first"
  fctl log "$follow_num" "cut from parent issue #$parent after part #$child merged; queued fresh, tier $tier"
  board_add_ready "$follow_num" "$follow_url"
  fctl set "$parent" \
    "blocked_reason=re-sliced automatically: remaining work is issue #$follow_num" \
    "resliced_to=$follow_num"
  fctl log "$parent" "part #$child merged; the next part is issue #$follow_num"
  return 0
}

# QA brief text, shared by the first dispatch (handle_pr_open) and a
# once-only respawn when the reviewer dies mid-round (handle_qa).
write_qa_brief() { # <out> <issue> <pr> <round> <branch> <worktree> [chunked]
  local out="$1" issue="$2" pr="$3" round="$4" branch="$5" worktree="$6" chunked="${7:-0}"
  {
    if [ "$chunked" = "1" ]; then
      echo "# QA round $round for issue #$issue (PR #$pr) - piece by piece"
      echo ""
      echo "You are a QA agent under the fleet daemon; there is no coordinator to message."
      echo "The previous reviewer said this diff is too big to review honestly in one"
      echo "sitting. Do NOT try to hold the whole change in view at once. Review it piece"
      echo "by piece: a few files at a time, keeping notes in a scratch file in the"
      echo "worktree as you go, and give ONE verdict at the end from your notes. Take as"
      echo "many passes as you need."
    else
      echo "# QA round $round for issue #$issue (PR #$pr)"
      echo ""
      echo "You are a QA agent under the fleet daemon; there is no coordinator to message."
      echo "This is round $round, so review INCREMENTALLY: focus on what changed since the"
      echo "last round (new commits and replies on PR #$pr), not a from-scratch re-review."
    fi
    echo "Branch: $branch. Worktree: $worktree."
    echo ""
    echo "Post your verdict as a PR comment, then record it (this exact command; \"fleetctl\""
    echo "alone is not on your PATH):"
    echo "- pass: node $SCRIPT_DIR/fleetctl.mjs set $issue status=qa-green qa_rounds=$round"
    echo "- fail: node $SCRIPT_DIR/fleetctl.mjs set $issue status=qa-red qa_rounds=$round"
    echo "- too big to honestly review, even piece by piece: comment why on the PR, then"
    echo "  node $SCRIPT_DIR/fleetctl.mjs set $issue status=qa-too-big qa_rounds=$round"
    echo "Never approve a change you could not actually read end to end: an honest"
    echo "too-big verdict beats a skimmed pass."
    echo "Then STOP your session. Never idle waiting."
    echo "Write everything a human reads in plain English, no jargon, plain ASCII"
    echo "punctuation, and pass this rule to anything you spawn."
  } > "$out"
}

# Fix brief text: a deliberate, self-terminating agent dispatched into the
# lane's existing worktree to clear a red check, a failed review, or a merge
# conflict. cause is "checks" (details = failing check names), "review"
# (details = the reviewer's findings, read off the pull request), or
# "merge conflicts" (details unused; the brief text is fixed by Unit 5's spec).
write_fix_brief() { # <out> <issue> <pr> <cause> <details> <round> <branch> <worktree>
  local out="$1" issue="$2" pr="$3" cause="$4" details="$5" round="$6" branch="$7" worktree="$8"
  local what
  if [ "$cause" = "checks" ]; then
    what="The checks are failing on PR #$pr. Failing checks: ${details:-<none named>}."
  elif [ "$cause" = "merge conflicts" ]; then
    what="PR #$pr cannot be merged: it has a conflict with main.
Bring this branch up to date with main, resolve the conflicts, push."
  else
    what="A review of PR #$pr found problems. The reviewer's findings:
${details:-<no comment found>}"
  fi
  {
    echo "# Fix brief for issue #$issue (PR #$pr), $cause round $round"
    echo ""
    echo "You are a fix agent under the fleet daemon; there is no coordinator to message."
    echo "The build agent that opened this PR has already ended its session, so this is a"
    echo "fresh session picking the work back up in the same worktree."
    echo ""
    echo "$what"
    echo ""
    echo "Branch: $branch. Worktree: $worktree."
    echo ""
    echo "Fix it, push your changes to the branch, then record it (this exact command;"
    echo "\"fleetctl\" alone is not on your PATH):"
    echo "node $SCRIPT_DIR/fleetctl.mjs set $issue status=pr-open"
    echo "Then STOP your session. Never idle waiting."
    echo "Write everything a human reads in plain English, no jargon, plain ASCII"
    echo "punctuation, and pass this rule to anything you spawn."
  } > "$out"
}

# Render the build brief from the template by replacing ${NAME} placeholders.
render_brief() { # <template> <out> ISSUE SPEC TIER BRANCH WORKTREE PR AGENT ROUND
  local template="$1" out="$2"
  local ISSUE="$3" SPEC="$4" TIER="$5" BRANCH="$6" WORKTREE="$7" PR="$8" AGENT="$9" ROUND="${10}"
  local text
  text="$(cat "$template")"
  # The record-keeping tool, at the address this daemon actually resolved --
  # the template must never hard-code a path that a repo move breaks.
  text="${text//\$\{FLEETCTL\}/${FLEETCTL[*]}}"
  text="${text//\$\{ISSUE\}/$ISSUE}"
  text="${text//\$\{SPEC\}/$SPEC}"
  text="${text//\$\{TIER\}/$TIER}"
  text="${text//\$\{BRANCH\}/$BRANCH}"
  text="${text//\$\{WORKTREE\}/$WORKTREE}"
  text="${text//\$\{PR\}/$PR}"
  text="${text//\$\{AGENT\}/$AGENT}"
  text="${text//\$\{ROUND\}/$ROUND}"
  printf '%s\n' "$text" > "$out"
}

# Lane agents live together in their own tab so they never land in a tab a
# person is working in. Overridable for a second fleet on the same box.
AGENT_TAB_LABEL="${FLEET_AGENT_TAB:-Fleet Agents}"

agent_tab_id() { # -> the tab lane agents share, or empty if it does not exist yet
  herdr tab list 2>/dev/null |
    jq -r --arg label "$AGENT_TAB_LABEL" \
      '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -n1
}

pane_in_tab() { # <tab-id> -> any pane in that tab, or empty
  herdr pane list 2>/dev/null |
    jq -r --arg tab "$1" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null |
    head -n1
}

# Lane agents share a family of tabs: "Fleet Agents", "Fleet Agents 2", and so
# on. Each tab holds at most four agent panes and grows through fixed shapes:
# one pane, two side by side, three columns, then a two-by-two square. The
# fifth agent starts the next tab. (Ben asked for exactly this on 2026-08-25.)
AGENT_TAB_MAX_PANES=4

fleet_tab_ids() { # -> ids of every fleet-labeled tab, in listing order
  herdr tab list 2>/dev/null |
    jq -r --arg label "$AGENT_TAB_LABEL" \
      '.result.tabs[]? | select((.label // "") == $label or ((.label // "") | startswith($label + " "))) | .tab_id' 2>/dev/null
}

tab_pane_geometry() { # <tab-id> -> lines "pane_id x y", top-to-bottom then left-to-right
  local any
  any="$(pane_in_tab "$1")"
  [ -z "$any" ] && return 0
  herdr pane layout --pane "$any" 2>/dev/null |
    jq -r '.result.layout.panes[]? | "\(.pane_id) \(.rect.x) \(.rect.y)"' 2>/dev/null |
    sort -t' ' -k3,3n -k2,2n
}

split_for_agent() { # <pane> <direction> <cwd> -> new pane id
  herdr pane split "$1" --direction "$2" --cwd "$3" --no-focus "${SANDBOX_ENV_ARGS[@]}" 2>/dev/null |
    jq -r '.result.pane_id // .result.pane.pane_id // empty' 2>/dev/null
}

new_fleet_tab() { # <cwd> -> root pane id of a fresh fleet tab
  local cwd="$1" n label
  n="$(fleet_tab_ids | grep -c .)"
  label="$AGENT_TAB_LABEL"
  [ "$n" -ge 1 ] && label="$AGENT_TAB_LABEL $((n + 1))"
  herdr tab create --cwd "$cwd" --label "$label" "${SANDBOX_ENV_ARGS[@]}" 2>/dev/null |
    jq -r '.result.root_pane.pane_id // empty' 2>/dev/null
}

# Give a lane agent a pane: fill the newest fleet tab up to four panes in the
# shapes above, or open the next tab. Every herdr call is best-effort; any
# missing answer falls back to opening a fresh tab so a spawn never dies over
# window dressing.
agent_pane() { # <cwd> -> a pane id ready for an agent, or empty
  local cwd="$1" tab count first mid last scratch
  tab="$(fleet_tab_ids | tail -n1)"
  if [ -z "$tab" ]; then
    new_fleet_tab "$cwd"
    return 0
  fi
  local geo=()
  mapfile -t geo < <(tab_pane_geometry "$tab")
  count="${#geo[@]}"
  if [ "$count" -eq 0 ] || [ "$count" -ge "$AGENT_TAB_MAX_PANES" ]; then
    new_fleet_tab "$cwd"
    return 0
  fi
  first="${geo[0]%% *}"
  last="${geo[$((count - 1))]%% *}"
  case "$count" in
    1) split_for_agent "$first" right "$cwd" ;;
    2) split_for_agent "$last" right "$cwd" ;;
    3)
      # Three columns become a square: the rightmost pane moves under the
      # leftmost, and the newcomer splits the middle column down. herdr treats
      # a move within its own tab as a no-op, so the pane bounces through a
      # throwaway tab on the way; the throwaway is closed once empty.
      mid="${geo[1]%% *}"
      herdr pane move "$last" --new-tab --no-focus >/dev/null 2>&1
      scratch="$(herdr pane list 2>/dev/null |
        jq -r --arg p "$last" '.result.panes[]? | select(.pane_id == $p) | .tab_id' 2>/dev/null)"
      herdr pane move "$last" --tab "$tab" --split down --target-pane "$first" --ratio 0.5 --no-focus >/dev/null 2>&1
      [ -n "$scratch" ] && [ "$scratch" != "$tab" ] && herdr tab close "$scratch" >/dev/null 2>&1
      split_for_agent "$mid" down "$cwd"
      ;;
    *) split_for_agent "$first" down "$cwd" ;;
  esac
}

# Spawn a lane agent in a fresh pane in the agents tab, pointed at a brief file.
spawn_agent() { # <name> <cwd> <brief-path> <tier>
  local name="$1" cwd="$2" brief="$3" tier="${4:-routine}"
  local model effort tool
  local launch_args=()
  model="$(tier_model "$tier")"
  effort="$(tier_effort "$tier")"
  tool="$(tier_tool "$tier")"
  mapfile -t launch_args < <(agent_launch_args "$tool" "$model" "$effort")
  local boot="You are a fleet lane agent. Read and follow the brief at $brief exactly. Report status in plain English, no jargon, and pass that rule to anything you spawn."
  if [ "$DRY" = "1" ]; then
    echo "DRY: herdr pane for $name in tab $AGENT_TAB_LABEL --cwd $cwd"
    echo "DRY: herdr agent start $name --kind $tool --pane <new-pane> -- ${launch_args[*]} \"$boot\""
    [ "$SANDBOX" = "1" ] && echo "DRY: sandbox: $name runs inside scripts/agent-sandbox.sh (writes limited to its own folders)"
    return 0
  fi
  local new_pane
  new_pane="$(agent_pane "$cwd")"
  if [ -z "$new_pane" ]; then
    echo "fleet-tick: could not open a pane in the $AGENT_TAB_LABEL tab for $name" >&2
    return 1
  fi
  local start_err attempt started=0
  local retry_wait="${FLEET_SPAWN_RETRY_SECONDS:-2}"
  start_err="$(mktemp)"
  # A pane split an instant ago may not have a running shell yet, and herdr
  # then refuses the start with agent_pane_busy ("is not an available shell").
  # Seen live twice on 2026-08-26 (07:36, 07:47); on a relay handoff the
  # failure parked the lane for a human. The shell only needs a moment, so
  # that one error retries the SAME pane, up to 3 attempts. Any other error
  # fails immediately. The stderr file is truncated per attempt, so on
  # failure it holds the last attempt's reason.
  for attempt in 1 2 3; do
    if herdr agent start "$name" --kind "$tool" --pane "$new_pane" -- "${launch_args[@]}" "$boot" >/dev/null 2>"$start_err"; then
      started=1
      break
    fi
    if [ "$attempt" -lt 3 ] && grep -q "agent_pane_busy" "$start_err"; then
      echo "fleet-tick: pane not ready for $name, retrying (attempt $((attempt + 1)) of 3)" >&2
      sleep "$retry_wait"
      continue
    fi
    break
  done
  if [ "$started" != "1" ]; then
    # Keep the reason: a discarded stderr here cost us the root cause of a real
    # spawn failure on 2026-08-24. One line, trimmed, into the journal.
    echo "fleet-tick: herdr agent start failed for $name: $(head -c 300 "$start_err" | tr '\n' ' ')" >&2
    rm -f "$start_err"
    # Close the pane opened above: a failed start otherwise leaves an empty
    # agent-less window behind on every attempt (lane 1951's hour-long
    # dispatch loop littered one per minute, 2026-08-25), and the finished-
    # pane sweep cannot see them because they never got an agent name.
    herdr pane close "$new_pane" >/dev/null 2>&1
    return 1
  fi
  rm -f "$start_err"
  return 0
}

# Every needs-ben entry and reply is matched on the fixed token "issue N",
# whole-token: a bare digit match would let issue 18 answer for issue 1834,
# or let a clock time (10:30) look like a reply naming issue 30.
needs_ben_issue_token_re() { # <issue> -> a grep -E pattern matching "issue N" as a whole token
  printf 'issue[[:space:]]+%s([^0-9]|$)' "$1"
}

needs_ben_entry_file() { # <issue> -> path of an existing entry, if any
  local issue="$1"
  grep -rlsE -- "$(needs_ben_issue_token_re "$issue")" "$NEEDS_BEN_DIR/queue" "$NEEDS_BEN_DIR/sent" 2>/dev/null | head -n1
}

# The oldest reply that names this issue and has not already been acted on
# (acted-on replies are renamed with a ".handled" suffix so they are never
# read twice). Empty if none.
needs_ben_reply_file() { # <issue> [asked-epoch] -> path, or empty
  local issue="$1" asked="${2:-0}" re line ts f
  [ -d "$NEEDS_BEN_DIR/replies" ] || return 0
  re="$(needs_ben_issue_token_re "$issue")"
  # Oldest first by modification time, via find rather than word-splitting ls
  # output -- a reply saved with a space in its filename must still be found.
  while IFS= read -r line; do
    ts="${line%% *}"; ts="${ts%%.*}"; f="${line#* }"
    [ -f "$f" ] || continue
    case "$f" in *.handled) continue ;; esac
    # A reply from before the current question was asked answers some EARLIER
    # question (replies are matched only on "issue N"); acting on it could
    # e.g. enable a merge Ben never approved. Skip anything older than the
    # asked-at stamp when the caller supplies one.
    case "$ts" in *[!0-9]*) ts=0 ;; esac
    if [ "$asked" -gt 0 ] && [ "$ts" -lt "$asked" ]; then continue; fi
    if grep -Eqs -- "$re" "$f"; then
      echo "$f"
      return 0
    fi
  done < <(find "$NEEDS_BEN_DIR/replies" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n)
}

needs_ben_reply_exists() { # <issue>
  [ -n "$(needs_ben_reply_file "$1")" ]
}

# --- needs-ben directory hygiene ---------------------------------------------
#
# sent/ and replies/ grow forever (162 and 67 files at the 2026-08-25 review)
# and every blocked lane greps both once per tick. Old files can no longer
# matter: a handled reply is never read again by design (skipped on its
# suffix), and an unhandled reply older than 14 days either never matched a
# lane or predates the lane's current question (a matching live reply is
# acted on within one tick of arriving). A sent entry that old is a question
# Ben has not answered in two weeks; archiving it makes the lane file the
# question afresh next tick, which both nudges Ben again and refreshes the
# asked-at stamp that keeps stale replies aged out. Files move to
# $NEEDS_BEN_DIR/archive/ -- outside every scanned path (the entry scan
# greps queue/ and sent/ recursively, the reply scan is -maxdepth 1 on
# replies/) -- and nothing is ever deleted.
needs_ben_archive_sweep() {
  local f
  [ -d "$NEEDS_BEN_DIR" ] || return 0
  [ "$DRY" = "1" ] || mkdir -p "$NEEDS_BEN_DIR/archive/sent" "$NEEDS_BEN_DIR/archive/replies"
  while IFS= read -r f; do
    act mv "$f" "$NEEDS_BEN_DIR/archive/replies/"
  done < <(find "$NEEDS_BEN_DIR/replies" -maxdepth 1 -type f \( -name '*.handled' -o -mtime +14 \) 2>/dev/null)
  while IFS= read -r f; do
    act mv "$f" "$NEEDS_BEN_DIR/archive/sent/"
  done < <(find "$NEEDS_BEN_DIR/sent" -maxdepth 1 -type f -mtime +14 2>/dev/null)
}

# The action in a reply is always its first meaningful word: "resume", or
# "merge", or anything else. A reply that opens with the "issue N" token
# (e.g. "issue 970: resume") has that token skipped first, so the token used
# to find the reply is never mistaken for the action itself.
reply_first_word() { # <reply text> -> lowercased first word
  local content="$1" w1 rest
  read -r w1 _ <<<"$content"
  w1="${w1,,}"
  if [ "$w1" = "issue" ]; then
    rest="$(sed -E 's/^[[:space:]]*[Ii]ssue[[:space:]]+[0-9]+[:,]?[[:space:]]*//' <<<"$content")"
    read -r w1 _ <<<"$rest"
    w1="${w1,,}"
  fi
  # Punctuation around the word never changes what Ben meant: his 2026-08-25
  # reply "resume, proceed with split" was refused for the comma alone and
  # the lane sat parked for three hours. Strip anything that is not a letter
  # or digit from the edges before matching.
  w1="$(sed -E 's/^[^a-z0-9]+//; s/[^a-z0-9]+$//' <<<"$w1")"
  printf '%s' "$w1"
}

ensure_needs_ben() { # <issue> <reason>
  local issue="$1" reason="$2" entry
  entry="$(needs_ben_entry_file "$issue")"
  if [ -n "$entry" ]; then
    # Already on Ben's phone with THIS question: leave everything alone so
    # the asked-at clock stays honest.
    grep -qsF -- "$reason" "$entry" && return 0
    # The lane re-parked on a DIFFERENT question. Merely re-stamping the
    # record here is the lane-1951 bug (2026-08-25): the stale entry keeps
    # the mismatch alive, the clock refreshes every tick, and every reply
    # Ben sends ages out as stale -- forever. Retire the old entry BEFORE
    # sending the new one (both carry the "issue N" token; retire-after
    # would leave two matching entries and the loop alive), then fall
    # through to file the new question exactly once.
    [ "$DRY" = "1" ] || mkdir -p "$NEEDS_BEN_DIR/retired"
    act mv "$entry" "$NEEDS_BEN_DIR/retired/"
  fi
  # The reply instructions ride on the question itself: a reply is only
  # matched back to this lane if it carries the "issue N" token, and Ben's
  # first real Telegram reply (2026-08-24, "Please reslice") was dropped
  # for lacking it. Never make him remember the format.
  act needs-ben fleet-daemon "issue $issue: $reason -- reply starting with 'issue $issue:' then resume, merge, or instructions"
  # Copy the question onto the lane record so the fleet screen can show it
  # without reading the needs-ben folder. Written once, when the question
  # is filed, so the asked-at clock stays honest.
  fctl set "$issue" "question=$reason" "questionAskedAt=$(date -Iseconds)"
}

pr_changed_files() { # <pr>
  # Nothing useful can come back once GitHub is refusing to answer this tick.
  [ "$TICK_STARVED" = "1" ] && return 1
  gh pr view "$1" --json files --jq '.files[].path' 2>/dev/null
}

# Best-effort read of the reviewer's findings, for the fix brief when a
# review failed: the most recent comment on the pull request.
pr_last_comment() { # <pr>
  gh pr view "$1" --json comments --jq '.comments[-1].body // empty' 2>/dev/null
}

# --- GitHub silence must never read as progress -------------------------------
#
# GitHub's hourly answer allowance is shared by every agent and tool on this
# box. When it runs out, the command the daemon relies on for check results
# prints a rate-limit error and still exits as if nothing were wrong, with no
# results. Left unhandled, that reads exactly like "the build is still
# running" and the lane waits forever, in silence. Below: a way to tell a
# starved answer from a quiet one, a second, usually-idle door to ask first,
# and a fleet-wide switch that stops burning one failed call per lane once
# the allowance is known to be gone.

gh_rate_limited() { # <captured stderr text>
  grep -qi "rate limit" <<<"$1"
}

TICK_STARVED=0
TICK_STARVED_LOGGED=0

# Marks the rest of this tick as not worth asking GitHub anything else; every
# starvation-aware caller below checks this first and skips its own gh call
# once it is set. Logged once per tick, at fleet level, never once per lane.
mark_tick_starved() {
  TICK_STARVED=1
  [ "$TICK_STARVED_LOGGED" = "1" ] && return 0
  TICK_STARVED_LOGGED=1
  fctl log fleet "ALARM: GitHub is refusing to answer (its hourly allowance is exhausted); skipping the rest of this tick's GitHub questions, will resume once the allowance resets"
}

# owner/name for this checkout's GitHub remote, for the REST door below.
repo_owner_name() {
  local remote
  remote="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)" || return 1
  case "$remote" in
    *github.com*) ;;
    *) return 1 ;;
  esac
  remote="${remote%.git}"
  remote="${remote#*github.com/}"
  remote="${remote#*github.com:}"
  [ -n "$remote" ] || return 1
  echo "$remote"
}

# Ask GitHub for a PR's check results. Tries the REST door first (a separate
# allowance from the one the older query-based command uses, and almost
# nothing else on this box competes for it), falling back to the older
# command only when REST itself gives nothing back. Sets PR_CHECKS to a JSON
# array of {name,bucket} on success, matching what callers already expect.
PR_CHECKS=""
PR_CHECKS_STARVED=0

pr_check_results() { # <pr> -> 0 and PR_CHECKS set, or 1 (see PR_CHECKS_STARVED)
  local pr="$1" owner_repo sha out err_file
  PR_CHECKS=""
  PR_CHECKS_STARVED=0
  if [ "$TICK_STARVED" = "1" ]; then
    PR_CHECKS_STARVED=1
    return 1
  fi
  owner_repo="$(repo_owner_name)"
  if [ -n "$owner_repo" ]; then
    err_file="$(mktemp)"
    # The branch tip is read through the same REST door as the check results
    # below; the older query-based command is only a fallback, because the
    # query door is the one that was empty in the live incident.
    sha="$(gh api "repos/$owner_repo/pulls/$pr" --jq '.head.sha' 2>"$err_file")"
    if [ -z "$sha" ] || [ "$sha" = "null" ]; then
      if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
        rm -f "$err_file"
        mark_tick_starved
        PR_CHECKS_STARVED=1
        return 1
      fi
      sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>"$err_file")"
    fi
    if [ -n "$sha" ] && [ "$sha" != "null" ]; then
      out="$(gh api "repos/$owner_repo/commits/$sha/check-runs" --jq \
        '[.check_runs[] | {name, bucket: (
           if .status != "completed" then "pending"
           elif (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "pass"
           elif (.conclusion == "cancelled" or .conclusion == "stale") then "cancel"
           else "fail" end)}]' 2>"$err_file")"
      if [ -n "$out" ] && [ "$out" != "null" ]; then
        PR_CHECKS="$out"
        rm -f "$err_file"
        return 0
      fi
    fi
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      PR_CHECKS_STARVED=1
      return 1
    fi
    rm -f "$err_file"
  fi
  # REST gave nothing and it was not a rate limit (no remote match, PR not
  # found yet, etc.) -- fall back to the older door before giving up.
  err_file="$(mktemp)"
  out="$(gh pr checks "$pr" --json name,bucket 2>"$err_file")"
  if [ -n "$out" ]; then
    PR_CHECKS="$out"
    rm -f "$err_file"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    PR_CHECKS_STARVED=1
    return 1
  fi
  rm -f "$err_file"
  return 1 # genuinely nothing to report yet; try again next tick
}

# Same treatment for a PR's open/closed/merged state, used when a lane is
# waiting to be reaped after merge.
PR_STATE=""

pr_merge_state() { # <pr> -> 0 and PR_STATE set, or 1
  local pr="$1" err_file out owner_repo
  PR_STATE=""
  [ "$TICK_STARVED" = "1" ] && return 1
  owner_repo="$(repo_owner_name)"
  if [ -n "$owner_repo" ]; then
    err_file="$(mktemp)"
    out="$(gh api "repos/$owner_repo/pulls/$pr" --jq 'if .merged then "MERGED" elif .state == "closed" then "CLOSED" else "OPEN" end' 2>"$err_file")"
    if [ -n "$out" ] && [ "$out" != "null" ]; then
      PR_STATE="$out"
      rm -f "$err_file"
      return 0
    fi
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    rm -f "$err_file"
  fi
  # REST gave nothing and it was not a rate limit -- fall back to the older
  # query door before giving up.
  err_file="$(mktemp)"
  out="$(gh pr view "$pr" --json state --jq '.state' 2>"$err_file")"
  if [ -n "$out" ]; then
    PR_STATE="$out"
    rm -f "$err_file"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    return 1
  fi
  rm -f "$err_file"
  return 1
}

# The PR's own answer for why it can or cannot be merged right now: CLEAN,
# BEHIND (base branch has moved on), DIRTY (real conflicts), or one of
# GitHub's other words (BLOCKED, UNSTABLE, DRAFT, ...). Used to route a
# failed or stuck auto-merge (Unit 5).
PR_MERGE_STATE_STATUS=""

pr_merge_state_status() { # <pr> -> 0 and PR_MERGE_STATE_STATUS set, or 1
  local pr="$1" err_file out owner_repo
  PR_MERGE_STATE_STATUS=""
  [ "$TICK_STARVED" = "1" ] && return 1
  owner_repo="$(repo_owner_name)"
  if [ -n "$owner_repo" ]; then
    err_file="$(mktemp)"
    out="$(gh api "repos/$owner_repo/pulls/$pr" --jq '.mergeable_state | ascii_upcase' 2>"$err_file")"
    if [ -n "$out" ] && [ "$out" != "null" ]; then
      PR_MERGE_STATE_STATUS="$out"
      rm -f "$err_file"
      return 0
    fi
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    rm -f "$err_file"
  fi
  # REST gave nothing and it was not a rate limit -- fall back to the older
  # query door before giving up.
  err_file="$(mktemp)"
  out="$(gh pr view "$pr" --json mergeStateStatus --jq '.mergeStateStatus' 2>"$err_file")"
  if [ -n "$out" ]; then
    PR_MERGE_STATE_STATUS="$out"
    rm -f "$err_file"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    return 1
  fi
  rm -f "$err_file"
  return 1
}

# --- done means closed out on GitHub (Unit 6) -----------------------------------
#
# A merged pull request does not make a lane done by itself. The daemon also
# has to close the issue (with a comment linking the merge) and move its
# project-board entry to Done, or the daemon's own word "done" and what the
# board actually shows can drift apart. Both actions are idempotent -- an
# already-closed issue or an already-Done board entry is nothing to do -- and
# both follow Unit 2's rules: a rate-limited answer backs off and retries
# next tick without being counted as a failure, and only a genuine failure
# counts toward the three-strikes cap that eventually lets the lane through
# anyway with a note.

ISSUE_STATE=""

issue_state() { # <issue> -> 0 and ISSUE_STATE set, or 1
  local issue="$1" err_file out owner_repo
  ISSUE_STATE=""
  [ "$TICK_STARVED" = "1" ] && return 1
  owner_repo="$(repo_owner_name)"
  if [ -n "$owner_repo" ]; then
    err_file="$(mktemp)"
    out="$(gh api "repos/$owner_repo/issues/$issue" --jq '.state | ascii_upcase' 2>"$err_file")"
    if [ -n "$out" ] && [ "$out" != "null" ]; then
      ISSUE_STATE="$out"
      rm -f "$err_file"
      return 0
    fi
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    rm -f "$err_file"
  fi
  # REST gave nothing and it was not a rate limit -- fall back to the older
  # query door before giving up.
  err_file="$(mktemp)"
  out="$(gh issue view "$issue" --json state --jq '.state' 2>"$err_file")"
  if [ -n "$out" ]; then
    ISSUE_STATE="$out"
    rm -f "$err_file"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    return 1
  fi
  rm -f "$err_file"
  return 1
}

# Closes the issue with a short comment linking the merged pull request.
# Checks first so an issue a human already closed is left alone: one log
# line, no double comment.
close_issue_on_github() { # <issue> <pr> -> 0 closed (already, freshly, or dry-run), 1 retry
  local issue="$1" pr="$2" err_file
  if [ "$DRY" = "1" ]; then
    echo "DRY: gh issue view $issue --json state (closeout: check before closing)"
    echo "DRY: gh issue close $issue --comment \"pull request #$pr merged this\""
    return 0
  fi
  issue_state "$issue" || return 1
  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    fctl log "$issue" "issue #$issue is already closed on GitHub; nothing to do"
    return 0
  fi
  err_file="$(mktemp)"
  if gh issue close "$issue" --comment "pull request #$pr merged this" 2>"$err_file"; then
    rm -f "$err_file"
    fctl log "$issue" "closed issue #$issue on GitHub with a comment linking merged PR #$pr"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    return 1
  fi
  fctl log "$issue" "closing issue #$issue on GitHub failed: $(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return 1
}

BOARD_ITEM_ID=""
BOARD_ITEM_STATUS=""

BOARD_FULL_FILE="board-items-full.json"

# `gh project item-list` asks GitHub for every field of every item and costs
# about 1,000 of the hourly 5,000 GraphQL points per read of this ~950 item
# board (measured live 2026-08-24). This asks for only what the daemon uses
# -- status, number, title, body, labels, repo, item id -- which GitHub
# prices at roughly 1 point per hundred items. The answer is reshaped to the
# exact shape `gh project item-list` returned, so every reader below stays
# unchanged. Note: a project owned by an organization (not a user) would
# need an organization(login:) root here; the fleet currently runs on
# user-owned projects ("@me" or a user login).
fetch_board_items() { # -> item-list shaped JSON on stdout; nothing + stderr on failure
  local root cursor="" page nodes_file
  if [ "$FLEET_PROJECT_OWNER" = "@me" ]; then
    root="viewer"
  else
    root="user(login: \"$FLEET_PROJECT_OWNER\")"
  fi
  nodes_file="$(mktemp)"
  while :; do
    page="$(gh api graphql \
      -f query="query(\$cursor: String) { ${root} { projectV2(number: ${FLEET_PROJECT_NUMBER}) { items(first: 100, after: \$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id
          fieldValueByName(name: \"Status\") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          content { __typename ... on Issue { number title body labels(first: 20) { nodes { name } } repository { nameWithOwner } } } } } } } }" \
      ${cursor:+-f cursor="$cursor"})" || { rm -f "$nodes_file"; return 1; }
    jq -c '(.data.viewer // .data.user).projectV2.items.nodes[]?
      | { id: .id,
          status: (.fieldValueByName.name // ""),
          labels: [.content.labels.nodes[]?.name],
          content: { type: (.content.__typename // ""), number: .content.number,
                     title: (.content.title // ""), body: (.content.body // ""),
                     repository: (.content.repository.nameWithOwner // "") } }' \
      <<<"$page" >> "$nodes_file" || { rm -f "$nodes_file"; return 1; }
    if [ "$(jq -r '(.data.viewer // .data.user).projectV2.items.pageInfo.hasNextPage' <<<"$page")" = "true" ]; then
      cursor="$(jq -r '(.data.viewer // .data.user).projectV2.items.pageInfo.endCursor' <<<"$page")"
    else
      break
    fi
  done
  jq -s '{items: .}' "$nodes_file"
  rm -f "$nodes_file"
}

# Finds this issue's entry on the board using the last board fetch on disk:
# an item's id never changes, so paying for a fresh read here buys nothing.
# A missing file (no successful board read yet) is a plain retry-next-tick;
# a status up to one read-spacing old risks at most one redundant move of a
# card a human just moved by hand. BOARD_ITEM_ID stays empty, with a 0
# return, when the issue simply has no entry there -- nothing to move then.
board_item_for_issue() { # <issue> -> 0 and BOARD_ITEM_ID/BOARD_ITEM_STATUS set, or 1
  local issue="$1"
  BOARD_ITEM_ID=""
  BOARD_ITEM_STATUS=""
  [ -f "$STATE_DIR/$BOARD_FULL_FILE" ] || return 1
  BOARD_ITEM_ID="$(jq -r --arg n "$issue" '.items[]? | select((.content.number|tostring) == $n) | .id // empty' "$STATE_DIR/$BOARD_FULL_FILE" | head -n1)"
  BOARD_ITEM_STATUS="$(jq -r --arg n "$issue" '.items[]? | select((.content.number|tostring) == $n) | .status // empty' "$STATE_DIR/$BOARD_FULL_FILE" | head -n1)"
  return 0
}

# Moves the issue's board entry to the named column. Checks first so an
# entry a human already moved is left alone: one log line, no double move.
# An issue with no board entry at all is also nothing to do -- there is
# nothing to move. The context word only flavours the dry-run lines, so a
# reader can tell a close-out move from a pickup move.
move_board_item() { # <issue> <column, e.g. Done> <context word> -> 0 moved (already, freshly, no entry, or dry-run), 1 retry
  local issue="$1" column="$2" context="$3"
  local err_file fields status_field_id option_id project_id column_lc
  column_lc="$(tr '[:upper:]' '[:lower:]' <<<"$column")"
  if [ "$DRY" = "1" ]; then
    echo "DRY: read last board fetch ($context: find issue #$issue's board entry)"
    echo "DRY: gh project item-edit ($context: move issue #$issue's board entry to $column)"
    return 0
  fi
  board_item_for_issue "$issue" || return 1
  if [ -z "$BOARD_ITEM_ID" ]; then
    fctl log "$issue" "issue #$issue has no project board entry; nothing to move"
    return 0
  fi
  if [ "$(tr '[:upper:]' '[:lower:]' <<<"${BOARD_ITEM_STATUS:-}")" = "$column_lc" ]; then
    fctl log "$issue" "issue #$issue's project board entry is already in $column; nothing to do"
    return 0
  fi
  err_file="$(mktemp)"
  project_id="$(gh project view "$FLEET_PROJECT_NUMBER" --owner "$FLEET_PROJECT_OWNER" --format json --jq '.id' 2>"$err_file")"
  if [ -z "$project_id" ]; then
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    fctl log "$issue" "moving issue #$issue's board entry to $column failed: could not read the board's own id"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  err_file="$(mktemp)"
  fields="$(gh project field-list "$FLEET_PROJECT_NUMBER" --owner "$FLEET_PROJECT_OWNER" --format json 2>"$err_file")"
  if [ -z "$fields" ]; then
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    fctl log "$issue" "moving issue #$issue's board entry to $column failed: could not read the board's status field"
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  status_field_id="$(jq -r '.fields[]? | select((.name|ascii_downcase)=="status") | .id // empty' <<<"$fields" | head -n1)"
  option_id="$(jq -r --arg col "$column_lc" '.fields[]? | select((.name|ascii_downcase)=="status") | .options[]? | select((.name|ascii_downcase)==$col) | .id // empty' <<<"$fields" | head -n1)"
  if [ -z "$status_field_id" ] || [ -z "$option_id" ]; then
    fctl log "$issue" "moving issue #$issue's board entry to $column failed: could not find a Status field with a $column option"
    return 1
  fi
  err_file="$(mktemp)"
  if gh project item-edit --id "$BOARD_ITEM_ID" --project-id "$project_id" --field-id "$status_field_id" --single-select-option-id "$option_id" >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    fctl log "$issue" "moved issue #$issue's project board entry to $column"
    return 0
  fi
  if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
    rm -f "$err_file"
    mark_tick_starved
    return 1
  fi
  fctl log "$issue" "moving issue #$issue's board entry to $column failed: $(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return 1
}

move_board_item_done() { # <issue> -> 0 moved (already, freshly, no entry, or dry-run), 1 retry
  move_board_item "$1" "Done" "closeout"
}

# The real board column is "In progress" (lowercase p); the lookup above does
# not care about case, but the log lines read better with the real spelling.
BOARD_PICKUP_COLUMN="In progress"

# Mirrors a pickup on the project board: the moment a build agent is really
# spawned, the issue's board entry moves to "In progress". UNLIKE close-out
# this must never hold the lane -- the build matters more than the board. A
# rate-limited answer leaves a note on the record so next tick retries the
# move; any other failure is one logged warning and nothing more.
note_board_pickup() { # <issue> -> always 0; the lane never waits on this
  local issue="$1"
  if move_board_item "$issue" "$BOARD_PICKUP_COLUMN" "pickup"; then
    return 0
  fi
  if [ "$TICK_STARVED" = "1" ]; then
    fctl set "$issue" board_move_pending=1
    fctl log "$issue" "GitHub is rate limiting; issue #$issue's board entry will be moved to $BOARD_PICKUP_COLUMN next tick"
    return 0
  fi
  fctl log "$issue" "warning: could not move issue #$issue's board entry to $BOARD_PICKUP_COLUMN; the build goes on regardless"
  return 0
}

# The retry half of the rule above, run from the main loop so it still
# happens even if the lane has already moved past building by the time
# GitHub answers again. A rate-limited retry keeps the note and waits for
# the next tick, not counted against anything; any other failure clears the
# note with one logged warning -- the board never holds a lane.
retry_board_pickup() { # <issue> -> always 0
  local issue="$1"
  if move_board_item "$issue" "$BOARD_PICKUP_COLUMN" "pickup"; then
    fctl set "$issue" board_move_pending=
    return 0
  fi
  [ "$TICK_STARVED" = "1" ] && return 0
  fctl set "$issue" board_move_pending=
  fctl log "$issue" "warning: could not move issue #$issue's board entry to $BOARD_PICKUP_COLUMN; giving up on the move, the build goes on"
  return 0
}

# Runs both close-out actions and decides whether the lane may move to done
# this tick. A rate-limited answer just backs off (not counted as a failure).
# A genuine failure of either action counts; after three such counted
# failures the lane is let through anyway, with a note on the record and on
# the board, rather than staying merged-but-not-closed-out forever.
close_out_github() { # <issue> <record> <pr> -> 0 lane may become done, 1 stay merging and retry
  local issue="$1" record="$2" pr="$3" attempts ok=1
  attempts="$(jq -r '.closeout_attempts // 0' <<<"$record")"

  close_issue_on_github "$issue" "$pr" || ok=0
  [ "$TICK_STARVED" = "1" ] && return 1
  move_board_item_done "$issue" || ok=0
  [ "$TICK_STARVED" = "1" ] && return 1

  [ "$ok" = "1" ] && return 0

  attempts=$((attempts + 1))
  if [ "$attempts" -ge 3 ]; then
    fctl set "$issue" "closeout_attempts=$attempts" "closeout_note=still open on GitHub after 3 attempts to close it out"
    fctl log "$issue" "gave up closing out issue #$issue on GitHub after 3 attempts; lane will be marked done anyway with a note on the board"
    return 0
  fi
  fctl set "$issue" "closeout_attempts=$attempts"
  fctl log "$issue" "issue #$issue is not fully closed out on GitHub yet (attempt $attempts of 3); will retry next tick"
  return 1
}

# A live-path proof comment must start with this exact line, nothing before
# it. A comment that only mentions the phrase in passing (including one
# saying the proof is missing) does not count.
LIVE_PATH_PROOF_MARKER="LIVE-PATH PROOF"

has_live_path_proof() { # <pr>
  local pr="$1"
  gh pr view "$pr" --json comments \
    --jq '.comments[] | (.body // "") | split("\n")[0]' 2>/dev/null \
    | grep -qx -- "$LIVE_PATH_PROOF_MARKER"
}

USER_FACING_RE='^(apps/web|packages/ui)/|^modules/[^/]+/(ui|web|frontend)/'

is_user_facing() { # <spec-path> <pr>
  local spec="$1" pr="$2"
  if grep -Eq "$USER_FACING_RE" <<<"$spec"; then return 0; fi
  if [ -n "$pr" ] && [ "$pr" != "null" ]; then
    if pr_changed_files "$pr" | grep -Eq "$USER_FACING_RE"; then return 0; fi
  fi
  return 1
}

# --- intake: the daemon loads its own queue from GitHub -------------------------

FLEET_PROJECT_NUMBER="${FLEET_PROJECT_NUMBER:-2}"
FLEET_PROJECT_OWNER="${FLEET_PROJECT_OWNER:-@me}"
# Runs are opt-in: only issues carrying this label are taken into the queue.
# Ben (or the launcher's picker screen) labels the issues a run should work;
# everything else on the board is simply left alone.
FLEET_RUN_LABEL="${FLEET_RUN_LABEL:-fleet-run}"

# One-shot tier call: reads the issue title/body, answers a single word.
intake_tier() { # <issue> <title> <body> -> tier word, or COMMAND-FAILED if the judge command itself could not run
  local issue="$1" title="$2" body="$3"
  local prompt tier out_file
  prompt="Assign a risk tier to this Jarv1s task issue. Mechanical triggers: anything touching auth, RLS, secrets, or migrations = SECURITY; shared tables, exports, or job payloads = SENSITIVE; everything else = ROUTINE. When in doubt, pick the higher tier.

Answer with a SINGLE first line containing exactly one word: SECURITY, SENSITIVE, or ROUTINE. Only the first line is read.

Issue #$issue: $title

$(head -c 4000 <<<"$body")"
  out_file="$(mktemp)"
  # shellcheck disable=SC2086 # JUDGE_CMD is a command, splitting is intended
  if ! $JUDGE_CMD "$prompt" >"$out_file" 2>&1; then
    rm -f "$out_file"
    echo "COMMAND-FAILED"
    return 0
  fi
  tier="$(head -n1 "$out_file" | tr -d '\r' | awk '{print tolower($1)}')"
  rm -f "$out_file"
  case "$tier" in
    security|sensitive|routine) echo "$tier" ;;
    *) echo "security" ;; # a working command that answered strangely = doubt = highest tier
  esac
}

# The GitHub web URL for an issue, derived from the repo's own remote.
issue_url() { # <issue number>
  local remote owner_repo
  remote="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)"
  owner_repo="$(sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' <<<"$remote")"
  if [ -n "$owner_repo" ]; then
    echo "https://github.com/$owner_repo/issues/$1"
  else
    echo "issue-#$1"
  fi
}

intake() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: gh api graphql [slim board read] (intake: find Ready/In Progress issues labeled $FLEET_RUN_LABEL with no record)"
    echo "DRY: $JUDGE_CMD [intake: assign a risk tier per new issue]"
    return 0
  fi
  # Once GitHub is refusing to answer this tick, intake's own reads (the board
  # list, branch and PR lookups per issue) would all fail the same way.
  [ "$TICK_STARVED" = "1" ] && return 0
  # The board changes on human time, not machine time. Reading the full
  # (nearly thousand item) board every minute burned most of GitHub's hourly
  # allowance (seen live 2026-08-24), so board reads keep a spacing: the
  # snapshot file's age says when the board was last read, and inside the
  # spacing window intake stays home. A newly labeled issue waits at most
  # this long before pickup. A failed read never writes the snapshot, so a
  # failure is retried on the very next tick, not after the full spacing.
  local last_read now_epoch
  if [ -f "$STATE_DIR/board-issues.json" ]; then
    last_read="$(stat -c %Y "$STATE_DIR/board-issues.json" 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if [ $((now_epoch - last_read)) -lt "${FLEET_BOARD_CHECK_SECONDS:-300}" ]; then
      return 0
    fi
  fi
  local items row n title body tier branch pr err_file
  err_file="$(mktemp)"
  items="$(fetch_board_items 2>"$err_file")"
  if [ -z "$items" ]; then
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 0
    fi
    rm -f "$err_file"
    return 0
  fi
  rm -f "$err_file"
  # The full fetch also lands on disk for the card movers: moving a card
  # needs the item's id, and reading the last fetch back costs nothing.
  printf '%s\n' "$items" > "$STATE_DIR/$BOARD_FULL_FILE.tmp-$$" 2>/dev/null \
    && mv "$STATE_DIR/$BOARD_FULL_FILE.tmp-$$" "$STATE_DIR/$BOARD_FULL_FILE" \
    || rm -f "$STATE_DIR/$BOARD_FULL_FILE.tmp-$$"
  # A snapshot of the board's Ready / In progress issues for the viewer's
  # Ready tab, so the screen can mirror the real board without doing GitHub
  # reads of its own. Refreshed every time intake fetches the board.
  jq -c --arg run_label "$(tr '[:upper:]' '[:lower:]' <<<"$FLEET_RUN_LABEL")" '[.items[]?
      | select((.content.type // "") == "Issue")
      | select(((.status // "") | ascii_downcase) as $s | $s == "ready" or $s == "in progress")
      | {number: .content.number, title: (.content.title // ""), column: (.status // ""),
         inRun: (((.labels // []) | map(ascii_downcase) | index($run_label)) != null),
         repo: ((.content.repository // "") | sub("^https?://github\\.com/"; ""))}]' \
    <<<"$items" > "$STATE_DIR/board-issues.json.tmp-$$" 2>/dev/null \
    && mv "$STATE_DIR/board-issues.json.tmp-$$" "$STATE_DIR/board-issues.json" \
    || rm -f "$STATE_DIR/board-issues.json.tmp-$$"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n="$(jq -r '.content.number // empty' <<<"$row")"
    [ -n "$n" ] || continue
    [ -f "$TASKS_DIR/$n.json" ] && continue # already has a record: idempotent
    title="$(jq -r '.content.title // .title // ""' <<<"$row")"
    body="$(jq -r '.content.body // ""' <<<"$row")"
    # The only hands-off case: an agent for this lane is live right now.
    # Adopting a lane someone is actively working would double-drive it.
    if issue_agent_live "$n"; then
      fctl log "$n" "intake skipped: an agent for issue #$n is live right now; re-check next tick"
      continue
    fi
    # Started-but-unfinished work is adopted, not skipped: find its branch and PR.
    branch="$(gh issue develop --list "$n" 2>/dev/null | head -n1 | cut -f1)"
    if [ -z "$branch" ]; then
      # The glob narrows the transfer, but a substring hit is not a match:
      # issue 195 must not adopt fleet/lane-1951. Keep only branch names
      # where the issue number appears as a whole token (digit-bounded),
      # same rule as needs_ben_issue_token_re.
      branch="$(git ls-remote --heads origin "*${n}*" 2>/dev/null | sed 's|.*refs/heads/||' \
        | grep -E "(^|[^0-9])${n}([^0-9]|$)" | head -n1)"
    fi
    pr=""
    if [ -n "$branch" ]; then
      pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
    fi
    tier="$(intake_tier "$n" "$title" "$body")"
    if [ "$tier" = "COMMAND-FAILED" ]; then
      judge_command_failed_alarm
      fctl log fleet "intake: could not tier issue #$n because the judge command failed to run; will try again next tick"
      continue
    fi
    # fleetctl add only accepts spec= and tier= (and requires spec); everything
    # else goes through set. Board issues have no spec file, so the issue URL
    # is the spec of record for an adopted lane.
    spec_url="$(issue_url "$n")"
    if [ -n "$pr" ]; then
      fctl add "$n" "spec=$spec_url" "tier=$tier"
      fctl set "$n" status=pr-open "pr=$pr" "branch=$branch"
      fctl log "$n" "intake: adopted issue #$n at pr-open (open PR #$pr on branch $branch), tier $tier"
    elif [ -n "$branch" ]; then
      fctl add "$n" "spec=$spec_url" "tier=$tier"
      fctl set "$n" "branch=$branch"
      fctl log "$n" "intake: adopted issue #$n at queued with existing branch $branch (dispatch will use a resume brief), tier $tier"
    else
      fctl add "$n" "spec=$spec_url" "tier=$tier"
      fctl log "$n" "intake: queued issue #$n fresh, tier $tier"
    fi
    # The record keeps the issue's title so every list a human scans (the
    # viewer's tabs, the board file) can say what the work is, not just its
    # number.
    if [ -n "$title" ]; then
      fctl set "$n" "title=$title"
    fi
  done < <(jq -c --arg run_label "$(tr '[:upper:]' '[:lower:]' <<<"$FLEET_RUN_LABEL")" '.items[]?
      | select((.content.type // "") == "Issue")
      # Compare case-insensitively: the real board column is "In progress"
      # (lowercase p), and an exact "In Progress" match would skip every
      # started task.
      | select(((.status // "") | ascii_downcase) as $s | $s == "ready" or $s == "in progress")
      # Opt-in: only issues labeled for a fleet run are taken. The board
      # query already returns the label names on every item, so this costs
      # no extra read. An unlabeled issue is simply not intaken: no record,
      # no log line. Taking the label OFF an issue that already has a record
      # changes nothing here -- intake never touches existing records, and
      # pausing or stopping a started lane stays the job of the viewer.
      | select(((.labels // []) | map(ascii_downcase) | index($run_label)) != null)' <<<"$items" 2>/dev/null)
}

log_if_new() { # <issue> <msg> -> log only when the lane's last log line differs
  local issue="$1" msg="$2" last
  last="${LOGMAP_MSG[$issue]:-}"
  [ "$last" = "$msg" ] && return 0
  fctl log "$issue" "$msg"
}

is_overnight() {
  local hour start="$OVERNIGHT_START_HOUR" end="$OVERNIGHT_END_HOUR"
  [ "$start" = "$end" ] && return 1
  hour=$((10#$(date +%H)))
  if [ "$start" -lt "$end" ]; then
    [ "$hour" -ge "$start" ] && [ "$hour" -lt "$end" ]
  else
    [ "$hour" -ge "$start" ] || [ "$hour" -lt "$end" ]
  fi
}

overnight_spec_gate() { # <issue> <record> -> 0: a written plan exists, dispatch may go ahead
  local issue="$1" record="$2" marker spec repo count
  # A recent "no plan found" answer is cached on disk for 30 minutes so a
  # queued lane does not re-ask GitHub every minute all night.
  marker="$STATE_DIR/.overnight-no-spec-$issue"
  if [ -f "$marker" ] && [ $((NOW_EPOCH - $(stat -c %Y "$marker" 2>/dev/null || echo 0))) -lt 1800 ]; then
    return 1
  fi
  # A plan counts if it is a spec file in the repo, or an issue comment whose
  # first line is exactly the word SPEC. The judgment model has standing
  # authority to write either one; the night only checks that one exists.
  if [ -f "$REPO_ROOT/docs/specs/$issue.md" ]; then
    rm -f "$marker"
    return 0
  fi
  spec="$(jq -r '.spec // ""' <<<"$record")"
  repo="$(sed -nE 's|^https://github.com/([^/]+/[^/]+)/issues/[0-9]+$|\1|p' <<<"$spec")"
  if [ -n "$repo" ]; then
    count="$(gh issue view "$issue" --repo "$repo" --json comments \
      --jq '[.comments[].body | select((split("\n")[0] | ascii_upcase) == "SPEC")] | length' 2>/dev/null)"
    case "$count" in '' | *[!0-9]*) count=0 ;; esac
    if [ "$count" -gt 0 ]; then
      rm -f "$marker"
      return 0
    fi
  fi
  touch "$marker"
  fctl log "$issue" "overnight rule: not dispatching, no written plan found (docs/specs/$issue.md or an issue comment whose first line is SPEC); the lane stays queued until a plan exists or the day window opens"
  return 1
}

# --- one function per status ----------------------------------------------------

handle_queued() { # <issue> <record>
  local issue="$1" record="$2"
  if [ "$LIVE_LANES" -ge "$LANE_CAP" ]; then
    return 0
  fi
  if ! budget_available; then
    return 0
  fi
  if ! memory_ok; then
    refuse_spawn_low_memory "$issue"
    return 0
  fi
  if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
    return 0
  fi
  # A lane sitting in the queue has no running stage, so a same-named agent
  # still open is a leftover from before the requeue (seen live on lane
  # 1955, 2026-08-25: Ben's resume was blocked for hours by the old build
  # agent's idle window plus its stale branch). This check must see every
  # registered agent, finished ones included -- a finished agent still
  # holds its name against a new spawn -- so it never goes through the
  # live-names list, which deliberately drops finished agents.
  close_issue_leftover_agents "$issue"
  case $? in
    1)
      log_if_new "$issue" "not spawning: an agent for issue #$issue is still working under one of the fleet's own names"
      return 0
      ;;
    2)
      # Leftovers closed this tick; dispatch next tick into a clean name.
      return 0
      ;;
  esac
  if is_overnight && ! overnight_spec_gate "$issue" "$record"; then
    return 0
  fi
  if [ ! -f "$BRIEF_TEMPLATE" ]; then
    fctl log "$issue" "dispatch failed: brief template missing at $BRIEF_TEMPLATE; lane stays queued"
    return 0
  fi
  local spec tier branch worktree agent brief resume
  spec="$(jq -r '.spec // ""' <<<"$record")"
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  branch="$(jq -r '.branch // empty' <<<"$record")"
  [ -n "$branch" ] || branch="fleet/lane-$issue"
  worktree="$REPO_ROOT/.claude/worktrees/fleet-lane-$issue"
  agent="fleet-lane-$issue"
  brief="$BRIEFS_DIR/brief-$issue-build.md"
  # Adopted lane: the branch already exists (on origin, or locally from an
  # earlier run of this lane), so the agent resumes it instead of starting
  # over. A local-only branch used to fall through to "git worktree add -b",
  # which can never succeed against an existing name -- that is what kept
  # lane 1955 from restarting after Ben's resume (2026-08-25).
  local local_branch=0
  git -C "$REPO_ROOT" show-ref --quiet --verify "refs/heads/$branch" && local_branch=1
  resume=0
  if [ "$local_branch" = "1" ] || [ -n "$(git -C "$REPO_ROOT" ls-remote --heads origin "$branch" 2>/dev/null | head -n1)" ]; then
    resume=1
  fi
  render_brief "$BRIEF_TEMPLATE" "$brief" "$issue" "$spec" "$tier" "$branch" "$worktree" "" "$agent" "1"
  if [ "$resume" = "1" ]; then
    {
      echo ""
      echo "## Resume, do not restart"
      echo ""
      echo "The branch $branch already exists (on origin or locally from an earlier"
      echo "run) with earlier work on this issue."
      echo "Fetch it, read its commit log, and FINISH it on that same branch: do not"
      echo "start over, do not create a new branch, and keep the work that is already"
      echo "there unless it is wrong. If a pull request does not exist yet, open one"
      echo "from this branch when the work is ready."
    } >> "$brief"
  fi
  if [ "$resume" = "1" ] && [ -d "$worktree" ]; then
    fctl log "$issue" "dispatch reusing existing worktree $worktree for branch $branch"
  elif [ "$local_branch" = "1" ]; then
    try_create_worktree "$issue" "$record" "$worktree" "$branch" || return 0
  elif [ "$resume" = "1" ]; then
    try_create_worktree "$issue" "$record" -b "$branch" "$worktree" "origin/$branch" || return 0
  else
    try_create_worktree "$issue" "$record" -b "$branch" "$worktree" origin/main || return 0
  fi
  if spawn_agent "$agent" "$worktree" "$brief" "$tier"; then
    fctl log "$issue" "spawn: build agent $agent in $worktree"
    note_spawn
    fctl set "$issue" status=building "agent=$agent" "branch=$branch" "worktree=$worktree"
    LIVE_LANES=$((LIVE_LANES + 1))
    # The board mirrors the pickup, but never gates it: the spawn above is
    # already done, and a board move that fails is a warning, not a blocker.
    note_board_pickup "$issue"
  else
    fctl log "$issue" "dispatch failed: could not spawn build agent $agent"
  fi
}

handle_building() { # <issue> <record>
  local issue="$1" record="$2"
  local agent tier updated age restart_count ruling attempts
  agent="$(jq -r '.agent // empty' <<<"$record")"
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  updated="$(jq -r '.updated_at // empty' <<<"$record")"
  [ -n "$agent" ] || return 0
  if herdr_agent_names | grep -qxF "$agent"; then
    # A live name is not proof of work: a session that relayed or wedged sits
    # open at its prompt reporting "idle" forever, and the lane freezes while
    # looking alive (seen live on lane 1951, 2026-08-25: eleven hours silent
    # behind an unsubmitted prompt). The name only settles this tick if the
    # agent is actually working or the lane has shown recent life; otherwise
    # the session is a corpse -- close it and fall through to the same
    # relay/restart handling as a vanished agent.
    if [ "$(herdr_agent_status "$agent")" = "working" ]; then
      return 0
    fi
    if ! lane_silent_for "$issue" "$record" "$STALE_SECONDS"; then
      return 0
    fi
    # Idle-corpse guard: a background test run still going in the worktree
    # means the agent is not actually finished; closing the session now
    # would kill the test with it.
    if hold_for_worktree_process "$issue" "$record"; then
      return 0
    fi
    fctl log "$issue" "build agent $agent is open but idle, and the lane has been silent for over 30 minutes; closing the dead session and treating the agent as gone"
    close_named_pane "$agent"
  fi
  # An agent that relayed (bumping .relays was its last act before stopping)
  # asked for a fresh session of itself. Send the successor now, instead of
  # waiting out the 30-minute dead-lane timer and rolling a judgment call --
  # the relay count exceeding the count of relay respawns in this lane's log
  # is how an intentional handoff is told apart from a death.
  local relays respawns
  relays="$(jq -r '.relays // 0' <<<"$record")"
  respawns="${LOGMAP_RELAY_RESPAWNS[$issue]:-0}"
  # Ben's standing rule keeps a waived lane resuming forever, but forever
  # should not be invisible: at every 6th relay, leave one de-duped ALARM
  # (log_if_new keeps it to one line per count) so the morning board shows
  # a lane that keeps handing off without finishing. Nothing is parked.
  if [ "$(jq -r '.relay_cap_waived // 0' <<<"$record")" = "1" ] \
    && [ "$relays" -ge 6 ] && [ $((relays % 6)) -eq 0 ]; then
    log_if_new "$issue" "ALARM: this lane has relayed $relays times under the standing resume rule; it keeps handing off without finishing - worth a human look"
  fi
  if [ "$relays" -gt "${respawns:-0}" ]; then
    if ! budget_available_recovery; then
      log_if_new "$issue" "relay successor waiting: spawn budget exhausted"
      return 0
    fi
    if ! memory_ok; then
      log_if_new "$issue" "relay successor waiting: free memory below the floor"
      return 0
    fi
    [ "$TERMINAL_MANAGER_DOWN" = "1" ] && return 0
    # The predecessor's finished pane usually still holds the name; it is a
    # leftover, not a worker (the live list above says the agent is gone).
    close_named_pane "$agent"
    local worktree brief
    worktree="$(jq -r '.worktree // empty' <<<"$record")"
    brief="$BRIEFS_DIR/brief-$issue-build.md"
    if [ -n "$worktree" ] && [ -f "$brief" ] && spawn_agent "$agent" "$worktree" "$brief" "$tier"; then
      note_spawn
      fctl log "$issue" "relay: respawned build agent $agent to continue after relay $relays"
      fctl set "$issue" status=building "agent=$agent"
    else
      fctl set "$issue" status=blocked "blocked_reason=relay successor spawn failed; parked for Ben"
      fctl log "$issue" "relay successor spawn failed (missing worktree or brief, or spawn error); parked"
    fi
    return 0
  fi
  [ -n "$updated" ] || return 0
  age=$((NOW_EPOCH - $(iso_to_epoch "$updated")))
  [ "$age" -ge "$STALE_SECONDS" ] || return 0
  # A RESTART ruling that could not be acted on (spawn budget gone, memory
  # low, terminal manager down) is remembered on the record, so the identical
  # judge question is not re-asked every tick while nothing has changed. Once
  # the block clears, the situation HAS changed: the stamp is cleared and the
  # judge is asked once more, same shape as the deputy's changed-reason rule.
  local held_ruling held_on
  held_ruling="$(jq -r '.judgment_answer // ""' <<<"$record")"
  held_on="$(jq -r '.judgment_hold // ""' <<<"$record")"
  if [ "$held_ruling" = "RESTART" ] && [ -n "$held_on" ]; then
    case "$held_on" in
      "spawn budget exhausted")       budget_available || return 0 ;;
      "free memory below the floor")  memory_ok || return 0 ;;
      "terminal manager unreachable") [ "$TERMINAL_MANAGER_DOWN" != "1" ] || return 0 ;;
    esac
    fctl set "$issue" judgment_answer= judgment_hold=
    fctl log "$issue" "the block that held the approved restart ($held_on) has cleared; asking the judge once more"
  fi
  restart_count="${LOGMAP_RESTARTS[$issue]:-0}"
  if [ "${restart_count:-0}" -ge 1 ]; then
    fctl set "$issue" status=blocked "blocked_reason=build agent died twice; parked for Ben"
    fctl log "$issue" "build agent died a second time; parked"
    return 0
  fi
  attempts="$(jq -r '.judgment_attempts // 0' <<<"$record")"
  judgment_call "$issue" "$record" 'RESTART or PARK' \
    "The build agent for issue $issue died mid-build (gone from the agent list, no record change for over 30 minutes). Should we restart it fresh with the same brief, or park the lane for Ben?"
  ruling="$RULING"
  if [ "$JUDGE_FAILED" = "1" ]; then
    # The command itself could not run -- not a strange answer. Never park on
    # this; leave the lane exactly as it is and try again next tick.
    return 0
  fi
  case "$ruling" in
    RESTART)
      if ! budget_available; then
        fctl set "$issue" judgment_answer=RESTART "judgment_hold=spawn budget exhausted"
        fctl log "$issue" "restart approved but spawn budget exhausted; ruling remembered, no re-ask until the budget recovers"
        return 0
      fi
      if ! memory_ok; then
        refuse_spawn_low_memory "$issue"
        fctl set "$issue" judgment_answer=RESTART "judgment_hold=free memory below the floor"
        fctl log "$issue" "restart approved but free memory is below the floor; ruling remembered, no re-ask until memory recovers"
        return 0
      fi
      if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
        fctl set "$issue" judgment_answer=RESTART "judgment_hold=terminal manager unreachable"
        fctl log "$issue" "restart approved but the terminal manager is unreachable; ruling remembered, no re-ask until it is back"
        return 0
      fi
      # The live list already says this agent is gone; a pane still holding
      # its name is a leftover, not a worker. Close it rather than letting a
      # corpse block the approved restart (seen live on lane 1889, where the
      # blocked restart also caused a second ask that flipped to PARK).
      close_named_pane "$agent"
      local worktree brief
      worktree="$(jq -r '.worktree // empty' <<<"$record")"
      brief="$BRIEFS_DIR/brief-$issue-build.md"
      if [ -n "$worktree" ] && [ -f "$brief" ] && spawn_agent "$agent" "$worktree" "$brief" "$tier"; then
        fctl log "$issue" "restart: respawned build agent $agent with the same brief"
        fctl log "$issue" "spawn: build agent $agent (restart)"
        note_spawn
        fctl set "$issue" status=building "agent=$agent"
      else
        fctl set "$issue" status=blocked "blocked_reason=restart failed; parked for Ben"
        fctl log "$issue" "restart failed (missing worktree or brief, or spawn error); parked"
      fi
      ;;
    PARK)
      fctl set "$issue" status=blocked "blocked_reason=dead lane parked by judgment call"
      fctl log "$issue" "dead lane parked by judgment call"
      ;;
    *)
      if [ "$DRY" = "1" ]; then
        : # dry-run: no real answer came back, nothing to count
      else
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 3 ]; then
          fctl set "$issue" status=blocked \
            "blocked_reason=dead lane judgment did not get a clear answer after 3 tries; last answer: ${RAW_ANSWER:-<no answer>}" \
            "judgment_attempts=$attempts"
          fctl log "$issue" "dead lane judgment gave up after 3 tries with no clear ruling; parked with the model's last answer"
        else
          fctl set "$issue" "judgment_attempts=$attempts"
          fctl log "$issue" "judgment answer did not parse; will ask again next tick ($attempts of 3 tries used)"
        fi
      fi
      ;;
  esac
}

# Asks GitHub to re-run the most recent workflow run on this branch. A plain
# API call, no model involved. Returns 1 (nothing found to re-run) when no
# run turns up -- the daemon still counts the attempt as spent, since a run
# that never existed is never going to finish either. A rate-limited answer
# is different: it marks the tick starved (like every other GitHub call
# here) and the caller must NOT count the attempt as spent.
request_checks_rerun() { # <branch> -> 0 requested, 1 no run found or GitHub starved
  local branch="$1" run_id err_file
  [ -n "$branch" ] || return 1
  [ "$TICK_STARVED" = "1" ] && return 1
  err_file="$(mktemp)"
  run_id="$(gh run list --branch "$branch" --limit 1 --json databaseId --jq '.[0].databaseId' 2>"$err_file")"
  if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
    if gh_rate_limited "$(cat "$err_file" 2>/dev/null)"; then
      rm -f "$err_file"
      mark_tick_starved
      return 1
    fi
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  act gh run rerun "$run_id"
  return 0
}

# Checks pending forever is an open-ended wait too (a CI outage at 3am holds
# the lane slot all night). Ninety minutes in, ask GitHub to re-run them
# once; ninety minutes after that with still no news, park with a plain
# reason instead of waiting again (Ben's ruling, 2026-08-23).
handle_checks_pending() { # <issue> <record>
  local issue="$1" record="$2"
  local updated age rerun_requested branch
  updated="$(jq -r '.updated_at // empty' <<<"$record")"
  [ -n "$updated" ] || return 0
  age=$((NOW_EPOCH - $(iso_to_epoch "$updated")))
  [ "$age" -ge "$CHECKS_PENDING_DEADLINE_SECONDS" ] || return 0
  rerun_requested="$(jq -r '.checks_rerun_requested // 0' <<<"$record")"
  if [ "$rerun_requested" -ge 1 ]; then
    fctl set "$issue" status=blocked "blocked_reason=checks never finished"
    fctl log "$issue" "checks still pending 90 minutes after the re-run request; parked as checks never finished"
    return 0
  fi
  branch="$(jq -r '.branch // empty' <<<"$record")"
  if request_checks_rerun "$branch"; then
    fctl log "$issue" "checks have been pending 90 minutes; asked GitHub to re-run them; will wait up to another 90 minutes"
  elif [ "$TICK_STARVED" = "1" ]; then
    # GitHub refused to answer, so nothing was actually asked: the one
    # re-run attempt is not spent, and the lane tries again next tick.
    return 0
  else
    fctl log "$issue" "checks have been pending 90 minutes; found no run to re-run; will wait up to another 90 minutes anyway"
  fi
  fctl set "$issue" "checks_rerun_requested=1"
}

handle_pr_open() { # <issue> <record>
  local issue="$1" record="$2"
  local pr checks failing pending tier
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  pr="$(jq -r '.pr // empty' <<<"$record")"
  if [ -z "$pr" ]; then
    fctl log "$issue" "status is pr-open but the record has no PR number"
    return 0
  fi
  # A fix agent hands the lane back to pr-open as its last act; if it left
  # its commits unpushed, the checks about to be consulted describe the old
  # tip. Settle the round (auto-push, loud no-op alarm) before asking GitHub.
  settle_fix_round "$issue" "$record"
  if ! pr_check_results "$pr"; then
    return 0 # not reportable yet, or GitHub is starved (already logged at fleet level)
  fi
  checks="$PR_CHECKS"
  failing="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(",")' <<<"$checks" 2>/dev/null)"
  pending="$(jq -r '[.[] | select(.bucket == "pending")] | length' <<<"$checks" 2>/dev/null)"
  if [ -n "$failing" ]; then
    act gh pr comment "$pr" --body "CI is red on this PR. Failing checks: $failing. Please fix and push; the fleet daemon will re-check."
    fctl log "$issue" "ci-red: failing checks: $failing"
    fctl set "$issue" status=ci-red
    return 0
  fi
  if [ "${pending:-0}" -gt 0 ]; then
    handle_checks_pending "$issue" "$record"
    return 0
  fi
  # Green: spawn an incremental QA round.
  if ! budget_available; then
    log_if_new "$issue" "CI green but spawn budget exhausted; QA spawn deferred"
    return 0
  fi
  if ! memory_ok; then
    refuse_spawn_low_memory "$issue"
    return 0
  fi
  if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
    return 0
  fi
  local qa_rounds round qa_agent worktree branch brief
  qa_rounds="$(jq -r '.qa_rounds // 0' <<<"$record")"
  round=$((qa_rounds + 1))
  qa_agent="fleet-qa-$issue-r$round"
  # Reaching pr-open means the previous agent declared itself finished --
  # writing this status is its last act -- so lingering panes from earlier
  # stages must not hold the reviewer back (seen live 2026-08-25: three
  # finished panes flagged "idle" would have frozen lane 1890 here). Only a
  # pane already holding the reviewer's exact name blocks this spawn.
  if pane_name_exists "$qa_agent"; then
    log_if_new "$issue" "not spawning QA: $qa_agent already has a pane"
    return 0
  fi
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  branch="$(jq -r '.branch // empty' <<<"$record")"
  # A lane adopted with an already-open pull request has no worktree yet.
  # Give it one before any agent is spawned into it, rather than letting the
  # reviewer run in the shared checkout several human sessions co-edit.
  if [ -z "$worktree" ]; then
    if [ -z "$branch" ]; then
      fctl log "$issue" "QA dispatch failed: no branch on record, cannot create a worktree"
      return 0
    fi
    worktree="$REPO_ROOT/.claude/worktrees/fleet-lane-$issue"
    if [ -d "$worktree" ]; then
      fctl log "$issue" "QA dispatch reusing existing worktree $worktree for branch $branch"
    elif git -C "$REPO_ROOT" show-ref --quiet --verify "refs/heads/$branch"; then
      try_create_worktree "$issue" "$record" "$worktree" "$branch" || return 0
    else
      try_create_worktree "$issue" "$record" -b "$branch" "$worktree" "origin/$branch" || return 0
    fi
    fctl set "$issue" "worktree=$worktree"
  fi
  brief="$BRIEFS_DIR/brief-$issue-qa-r$round.md"
  write_qa_brief "$brief" "$issue" "$pr" "$round" "$branch" "$worktree"
  if spawn_agent "$qa_agent" "${worktree:-$REPO_ROOT}" "$brief" "$tier"; then
    fctl log "$issue" "spawn: QA agent $qa_agent for round $round"
    note_spawn
    # The builder's own name stays in "agent" -- the reviewer gets its own
    # field so a dead review round is never confused with a dead build.
    fctl set "$issue" status=qa "reviewer=$qa_agent"
  else
    fctl log "$issue" "QA dispatch failed: could not spawn $qa_agent"
  fi
}

# Stranded-push guard. A fix agent that commits in the lane worktree but
# never pushes leaves the remote tip unchanged: checks re-run against the old
# commit, fail identically, and a whole fresh fix round is burned (happened
# twice on lane 1970, 2026-08-25). fix_round_base, stamped at fix spawn time
# with the remote tip sha, lets the round's end answer two questions:
#   a) did the agent leave commits unpushed? If the local branch is strictly
#      ahead of the recorded remote tip, push them (a plain push, NEVER
#      force -- force-push is on Ben's hard floor) and log it.
#   b) did the round change the remote at all? If the tip after (a) is still
#      exactly the recorded base, the round produced nothing: one loud ALARM
#      line, and the existing round counting proceeds unchanged.
# A missing worktree or a diverged history is logged and skipped. Runs once
# per round: the base stamp is cleared on entry.
settle_fix_round() { # <issue> <record> -> always 0
  local issue="$1" record="$2"
  local base branch worktree remote_sha local_sha pushed=0 new_tip
  base="$(jq -r '.fix_round_base // empty' <<<"$record")"
  [ -n "$base" ] || return 0
  fctl set "$issue" fix_round_base=
  branch="$(jq -r '.branch // empty' <<<"$record")"
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  if [ -z "$branch" ]; then
    fctl log "$issue" "fix round ended but the record has no branch; skipping the stranded-push check"
    return 0
  fi
  remote_sha="$(git -C "$REPO_ROOT" ls-remote --heads origin "$branch" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$remote_sha" ]; then
    fctl log "$issue" "fix round ended but the remote tip of $branch could not be read; skipping the stranded-push check"
    return 0
  fi
  if [ -z "$worktree" ] || [ ! -d "$worktree" ]; then
    fctl log "$issue" "fix round ended but the worktree is gone; cannot check for unpushed commits"
  else
    local_sha="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
    if [ -n "$local_sha" ] && [ "$local_sha" != "$remote_sha" ]; then
      if git -C "$worktree" cat-file -e "$remote_sha" 2>/dev/null \
        && git -C "$worktree" merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
        if act git -C "$worktree" push origin "$branch"; then
          pushed=1
          fctl log "$issue" "the fix round left commits unpushed in the worktree; the daemon pushed them to origin/$branch"
        else
          fctl log "$issue" "the fix round left commits unpushed, but the push failed; leaving them for the next round to find"
        fi
      else
        fctl log "$issue" "the fix round left local commits that do not build on the remote tip (histories diverged); not pushing (force-push is never allowed)"
      fi
    fi
  fi
  new_tip="$remote_sha"
  [ "$pushed" = "1" ] && new_tip="$local_sha"
  if [ "$new_tip" = "$base" ]; then
    fctl log "$issue" "ALARM: the fix round ended with the remote branch exactly where it started; the round produced nothing that reached GitHub"
  fi
  return 0
}

# A fix agent's last act is meant to be pushing its fix and handing the lane
# back to pr-open, but an agent that pushes and then exits without writing the
# status leaves the lane sitting on a red verdict that no longer describes the
# branch. Seen live 2026-08-26 on issue 1975: the round-2 fix pushed at
# 05:11:26, GitHub started a fresh check run seventeen seconds later, and the
# 05:13 tick parked the lane as a third failure while that run was still in
# progress. This asks GitHub whether the red verdict still describes the
# branch tip before a round is burned or the lane is parked. Answers 0 when
# the verdict is stale (fresh work is still being judged), 1 when the red is
# current -- and 1 whenever GitHub gives nothing back, so a failed read keeps
# today's behavior instead of guessing.
red_verdict_is_stale() { # <issue> <record> <cause> <pr> -> 0 stale, 1 current (or unknown)
  local issue="$1" record="$2" cause="$3" pr="$4"
  local failing pushed updated
  [ -n "$pr" ] || return 1
  case "$cause" in
    checks)
      # One bounded read of the branch tip's check results. Failing checks on
      # the tip mean the red is real right now, whatever else moved. Anything
      # still pending -- the live incident -- or a tip with no red at all
      # (the verdict was for an older commit) goes back to the normal
      # watcher, which already knows how to judge a run in flight.
      pr_check_results "$pr" || return 1
      failing="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' <<<"$PR_CHECKS" 2>/dev/null)"
      [ "${failing:-0}" -gt 0 ] && return 1
      return 0
      ;;
    review)
      # A review verdict never re-runs by itself, so the check results say
      # nothing here. Instead: did anyone push after the record last moved?
      # (Its last move before this point was spawning the current fix round.)
      # A newer tip commit means the fix landed and deserves judgment; the
      # commit's own timestamp can lag the push after a rebase, and that
      # reads as "not newer" -- which safely degrades to today's behavior.
      [ "$TICK_STARVED" = "1" ] && return 1
      pushed="$(gh pr view "$pr" --json commits --jq '.commits[-1].committedDate // empty' 2>/dev/null)"
      [ -n "$pushed" ] || return 1
      updated="$(jq -r '.updated_at // empty' <<<"$record")"
      [ -n "$updated" ] || return 1
      [ "$(iso_to_epoch "$pushed")" -gt "$(iso_to_epoch "$updated")" ]
      ;;
    *)
      # Merge conflicts have no cheap staleness signal; that path is unchanged.
      return 1
      ;;
  esac
}

# Dispatches a fix agent for a red check or a failed review. Waits rather
# than re-dispatching while the current round's agent is still alive; bounds
# each cause at two rounds, parking with a question for Ben on the third.
dispatch_fix_agent() { # <issue> <record> <cause: checks|review> <field: ci_fix_rounds|qa_fix_rounds> <details> <pr>
  local issue="$1" record="$2" cause="$3" field="$4" details="$5" pr="$6"
  local agent rounds round tier branch worktree brief fix_agent tok
  agent="$(jq -r '.agent // empty' <<<"$record")"
  # Only a fix agent still at work holds this round open. At the first red
  # verdict the record's agent still names the builder -- finished by
  # definition, its PR is open -- and the builder's lingering pane must not
  # block the fix (its done/idle flag is untrustworthy; see pane_name_exists).
  case "$agent" in
    fleet-fix-*)
      if herdr_agent_names | grep -qxF "$agent"; then
        return 0 # this round's fix agent is still working
      fi
      # Idle-corpse guard: the fix agent's session has stopped, but a test
      # run it left in the background may still be going in the worktree.
      # Advancing the round now would reap the pane and kill that run.
      if hold_for_worktree_process "$issue" "$record"; then
        return 0
      fi
      # Stranded-push guard: the round just concluded; push any commits the
      # fix agent left unpushed, and say so loudly if the remote never moved.
      settle_fix_round "$issue" "$record"
      ;;
  esac
  # Before a round is burned or the lane parked, make sure the red verdict
  # still describes the branch tip: a fix that was pushed but never judged
  # (its agent exited without restoring pr-open) must be judged, not counted
  # as another failure. Handing the lane back to pr-open lets the normal
  # watcher run the usual green/red/pending logic on the fresh state.
  if red_verdict_is_stale "$issue" "$record" "$cause" "$pr"; then
    fctl set "$issue" status=pr-open
    fctl log "$issue" "the $cause verdict predates the newest work on the branch; back to pr-open so the fresh state is judged instead of burning a fix round"
    return 0
  fi
  rounds="$(jq -r --arg f "$field" '.[$f] // 0' <<<"$record")"
  if [ "$rounds" -ge 2 ]; then
    fctl set "$issue" status=blocked "blocked_reason=$cause failed a third time; needs Ben"
    fctl log "$issue" "$cause failed a third time in a row; parked with a question for Ben"
    # The park used to only PROMISE a question for Ben: it wrote the log line
    # above and stopped, so nothing ever reached his phone (seen on issue
    # 1975). File the question the same way every other park path does.
    ensure_needs_ben "$issue" "$cause failed a third time in a row and the fleet is out of retries - look at the lane, or reply resume to let it try again"
    return 0
  fi
  if ! budget_available_recovery; then
    park_budget_exhausted "$issue"
    return 0
  fi
  if ! memory_ok; then
    refuse_spawn_low_memory "$issue"
    return 0
  fi
  if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
    return 0
  fi
  round=$((rounds + 1))
  # Cause-unique name: ci/qa/merge rounds are separate counters, so a shared
  # fleet-fix-N-rK pattern collides across causes (e.g. ci r1 vs merge r1)
  # and the pane check below then skips the spawn forever.
  tok="${field%_fix_rounds}"
  fix_agent="fleet-fix-$issue-$tok-r$round"
  if pane_name_exists "$fix_agent"; then
    if herdr_agent_names | grep -qxF -- "$fix_agent"; then
      log_if_new "$issue" "not spawning a fix agent: $fix_agent already has a pane"
      return 0
    fi
    # Exact name taken but its agent is finished: a stale pane must not block
    # the retry forever. Close it and respawn.
    fctl log "$issue" "closing the stale pane of finished agent $fix_agent before respawning"
    close_named_pane "$fix_agent"
  fi
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  branch="$(jq -r '.branch // empty' <<<"$record")"
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  brief="$BRIEFS_DIR/brief-$issue-fix-$tok-r$round.md"
  write_fix_brief "$brief" "$issue" "$pr" "$cause" "$details" "$round" "$branch" "$worktree"
  if spawn_agent "$fix_agent" "${worktree:-$REPO_ROOT}" "$brief" "$tier"; then
    fctl log "$issue" "spawn: fix agent $fix_agent ($cause round $round)"
    note_spawn
    # Remember where the remote tip stood when this round began, so the
    # round's end can tell a real fix from one that never reached GitHub
    # (the stranded-push guard; see settle_fix_round).
    local base_sha=""
    [ -n "$branch" ] && base_sha="$(git -C "$REPO_ROOT" ls-remote --heads origin "$branch" 2>/dev/null | awk 'NR==1{print $1}')"
    if [ -n "$base_sha" ]; then
      fctl set "$issue" "agent=$fix_agent" "$field=+1" "fix_round_base=$base_sha"
    else
      fctl set "$issue" "agent=$fix_agent" "$field=+1"
    fi
  else
    fctl log "$issue" "fix dispatch failed: could not spawn $fix_agent"
  fi
}

handle_ci_red() { # <issue> <record>
  local issue="$1" record="$2"
  local pr failing
  pr="$(jq -r '.pr // empty' <<<"$record")"
  failing="${LOGMAP_CI_RED_LAST[$issue]:-}"
  failing="${failing#ci-red: failing checks: }"
  dispatch_fix_agent "$issue" "$record" checks ci_fix_rounds "$failing" "$pr"
}

handle_qa() { # <issue> <record>
  local issue="$1" record="$2"
  local reviewer updated age restarts
  reviewer="$(jq -r '.reviewer // empty' <<<"$record")"
  updated="$(jq -r '.updated_at // empty' <<<"$record")"
  [ -n "$reviewer" ] || return 0
  if herdr_agent_names | grep -qxF "$reviewer"; then
    return 0 # reviewer is alive and working
  fi
  [ -n "$updated" ] || return 0
  age=$((NOW_EPOCH - $(iso_to_epoch "$updated")))
  [ "$age" -ge "$REVIEW_STALE_SECONDS" ] || return 0
  restarts="${LOGMAP_REVIEWER_RESTARTS[$issue]:-0}"
  if [ "${restarts:-0}" -ge 1 ]; then
    fctl set "$issue" status=blocked "blocked_reason=reviewer died twice; parked for Ben"
    fctl log "$issue" "reviewer died a second time; parked"
    return 0
  fi
  if ! budget_available_recovery; then
    park_budget_exhausted "$issue"
    return 0
  fi
  if ! memory_ok; then
    refuse_spawn_low_memory "$issue"
    return 0
  fi
  if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
    return 0
  fi
  local pr qa_rounds round tier branch worktree brief new_reviewer
  pr="$(jq -r '.pr // empty' <<<"$record")"
  qa_rounds="$(jq -r '.qa_rounds // 0' <<<"$record")"
  round=$((qa_rounds + 1))
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  branch="$(jq -r '.branch // empty' <<<"$record")"
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  new_reviewer="fleet-qa-$issue-r$round-retry"
  # The dead reviewer's own pane may linger; only a pane already holding the
  # replacement's exact name blocks the respawn.
  if pane_name_exists "$new_reviewer"; then
    log_if_new "$issue" "not respawning a reviewer: $new_reviewer already has a pane"
    return 0
  fi
  brief="$BRIEFS_DIR/brief-$issue-qa-r$round-retry.md"
  write_qa_brief "$brief" "$issue" "$pr" "$round" "$branch" "$worktree" \
    "$(jq -r '.chunked_review // 0' <<<"$record")"
  if spawn_agent "$new_reviewer" "${worktree:-$REPO_ROOT}" "$brief" "$tier"; then
    fctl log "$issue" "reviewer-restart: respawned QA agent for round $round after the first died"
    fctl log "$issue" "spawn: QA agent $new_reviewer (reviewer respawn, round $round)"
    note_spawn
    fctl set "$issue" "reviewer=$new_reviewer"
  else
    fctl set "$issue" status=blocked "blocked_reason=reviewer respawn failed; parked for Ben"
    fctl log "$issue" "reviewer respawn failed; parked"
  fi
}

handle_qa_red() { # <issue> <record>
  local issue="$1" record="$2"
  local pr findings
  pr="$(jq -r '.pr // empty' <<<"$record")"
  if [ -z "$pr" ]; then
    dispatch_fix_agent "$issue" "$record" review qa_fix_rounds "" "$pr"
    return 0
  fi
  if [ "$TICK_STARVED" = "1" ]; then
    return 0 # GitHub is starved this tick; the findings live in a PR comment, try again next tick
  fi
  findings="$(pr_last_comment "$pr")"
  dispatch_fix_agent "$issue" "$record" review qa_fix_rounds "$findings" "$pr"
}

# A reviewer that cannot honestly vouch for the whole diff says so instead of
# skimming (the brief offers the qa-too-big verdict). Ben's ruling
# (2026-08-25): that verdict never goes to his phone first -- he would only
# hand it back to another agent -- so the first too-big spawns ONE fresh
# reviewer told to work piece by piece within its limits (chunked_review=1
# marks the lane). Only when THAT reviewer also says too big does the lane
# park with a question for Ben.
handle_qa_too_big() { # <issue> <record>
  local issue="$1" record="$2"
  local pr qa_rounds round tier branch worktree brief qa_agent
  if [ "$(jq -r '.chunked_review // 0' <<<"$record")" = "1" ]; then
    fctl set "$issue" status=blocked \
      "blocked_reason=review says this change is too big to review honestly, even piece by piece"
    fctl log "$issue" "the piece-by-piece review also said too big; parked with the merge call for Ben"
    ensure_needs_ben "$issue" "the review says this change is too big to review honestly, even piece by piece - the merge call is yours"
    return 0
  fi
  if ! budget_available; then
    log_if_new "$issue" "review said too big but spawn budget exhausted; piece-by-piece review deferred"
    return 0
  fi
  if ! memory_ok; then
    refuse_spawn_low_memory "$issue"
    return 0
  fi
  if [ "$TERMINAL_MANAGER_DOWN" = "1" ]; then
    return 0
  fi
  pr="$(jq -r '.pr // empty' <<<"$record")"
  qa_rounds="$(jq -r '.qa_rounds // 0' <<<"$record")"
  round=$((qa_rounds + 1))
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  branch="$(jq -r '.branch // empty' <<<"$record")"
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  qa_agent="fleet-qa-$issue-r$round-chunked"
  if pane_name_exists "$qa_agent"; then
    log_if_new "$issue" "not spawning the piece-by-piece review: $qa_agent already has a pane"
    return 0
  fi
  brief="$BRIEFS_DIR/brief-$issue-qa-r$round-chunked.md"
  write_qa_brief "$brief" "$issue" "$pr" "$round" "$branch" "$worktree" 1
  if spawn_agent "$qa_agent" "${worktree:-$REPO_ROOT}" "$brief" "$tier"; then
    fctl log "$issue" "review said the diff is too big for one sitting; spawn: piece-by-piece QA agent $qa_agent for round $round"
    note_spawn
    fctl set "$issue" status=qa "reviewer=$qa_agent" chunked_review=1
  else
    fctl log "$issue" "piece-by-piece QA dispatch failed: could not spawn $qa_agent"
  fi
}

# Turns on auto-merge for a PR and reports whether the command itself
# succeeded. In dry-run this always reports success, like every other
# action here -- nothing really runs, so nothing can fail. MERGE_ERR carries
# the command's own error text when it genuinely fails.
MERGE_ERR=""

enable_auto_merge() { # <pr> -> 0 armed (or dry-run), or 1 failed with MERGE_ERR set
  local pr="$1" err_file
  MERGE_ERR=""
  if [ "$DRY" = "1" ]; then
    echo "DRY: gh pr merge $pr --squash --auto"
    return 0
  fi
  err_file="$(mktemp)"
  if gh pr merge "$pr" --squash --auto 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi
  MERGE_ERR="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return 1
}

# Branch merely behind main: a mechanical fix, no model needed. Ask GitHub
# to update the branch and retry auto-merge next tick. Two failed update
# attempts in a row park the lane -- something else is stopping it catching
# up (Unit 5).
route_merge_behind() { # <issue> <record> <pr>
  local issue="$1" record="$2" pr="$3" attempts
  attempts="$(jq -r '.merge_update_attempts // 0' <<<"$record")"
  if [ "$attempts" -ge 2 ]; then
    fctl set "$issue" status=blocked "blocked_reason=branch is behind main; two update attempts did not bring it current; needs Ben"
    fctl log "$issue" "branch still behind main after two update attempts; parked"
    return 0
  fi
  act gh pr update-branch "$pr"
  fctl set "$issue" status=qa-green "merge_update_attempts=$((attempts + 1))"
  fctl log "$issue" "branch behind main; asked GitHub to update it (attempt $((attempts + 1)) of 2); will retry auto-merge next tick"
}

# Routes a failed or stuck auto-merge by reading the PR's own merge-state
# answer: BEHIND is mechanical (route_merge_behind), DIRTY is a real
# conflict (a fix agent, unit 3's machinery, counted as a fix round), and
# anything else is a configuration problem no agent can fix -- park at once
# with context as the reason. context is either the merge command's own
# error text (a failed attempt) or a note that the lane has been stuck
# (the 45-minute re-check); either way it ends up in the parked reason.
route_merge_failure() { # <issue> <record> <pr> <context>
  local issue="$1" record="$2" pr="$3" context="$4" state reason
  pr_merge_state_status "$pr" || return 0
  state="$PR_MERGE_STATE_STATUS"
  case "$state" in
    BEHIND) route_merge_behind "$issue" "$record" "$pr" ;;
    DIRTY) dispatch_fix_agent "$issue" "$record" "merge conflicts" merge_fix_rounds "" "$pr" ;;
    *)
      reason="$context (GitHub's merge-state answer: ${state:-unknown})"
      fctl set "$issue" status=blocked "blocked_reason=$reason"
      fctl log "$issue" "auto-merge did not go through; parked with reason: $reason"
      ;;
  esac
}

handle_qa_green() { # <issue> <record>
  local issue="$1" record="$2"
  local pr spec tier
  pr="$(jq -r '.pr // empty' <<<"$record")"
  spec="$(jq -r '.spec // ""' <<<"$record")"
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  if [ -z "$pr" ]; then
    fctl log "$issue" "status is qa-green but the record has no PR number"
    return 0
  fi
  if [ "$TICK_STARVED" = "1" ]; then
    return 0 # GitHub is starved this tick; try this lane again next tick
  fi
  # Live-path gate: a user-facing change needs live proof recorded on the PR
  # before it may merge.
  if is_user_facing "$spec" "$pr"; then
    if ! has_live_path_proof "$pr"; then
      fctl set "$issue" status=blocked "blocked_reason=code-complete, unverified"
      fctl log "$issue" "user-facing PR #$pr has no live-path proof comment; parked as code-complete, unverified"
      return 0
    fi
  fi
  if [ "$tier" = "security" ]; then
    # No pause for Ben (his standing rule, 2026-08-24): security tier merges
    # on the same gates as everything else -- adversarial QA already passed,
    # checks are green, and the live-path proof was enforced above. The
    # merge is flagged loudly so it tops the morning board read.
    fctl log "$issue" "security tier: merging on standing authority, no sign-off pause (Ben's rule 2026-08-24); flag at the top of the morning board"
  fi
  # All tiers merge on auto (never --admin: blocked by a ruleset).
  if enable_auto_merge "$pr"; then
    fctl set "$issue" status=merging merge_update_attempts=0
    fctl log "$issue" "auto-merge enabled on PR #$pr"
  else
    route_merge_failure "$issue" "$record" "$pr" "${MERGE_ERR:-auto-merge was refused and gave no reason}"
  fi
}

close_lane_panes() { # <issue> — close every pane held by this lane's agents (exact-issue names only)
  local issue="$1" name pane
  herdr agent list 2>/dev/null \
    | jq -r --arg i "$issue" \
        '.result.agents[]? | select((.name // "") | test("^fleet-(lane|qa|fix|rescue)-" + $i + "(-|$)")) | "\(.name)\t\(.pane_id // "")"' 2>/dev/null \
    | while IFS=$'\t' read -r name pane; do
        [ -n "$pane" ] || continue
        if [ "$DRY" = "1" ]; then
          echo "DRY: herdr pane close $pane ($name)"
        else
          herdr pane close "$pane" >/dev/null 2>&1
        fi
      done
}

# Finished work must not leave its windows behind (Ben, 2026-08-25): an agent
# that has stopped (idle or done) on a lane that is settled -- done, parked,
# or with no record at all -- is a leftover, and its pane is closed here once
# per tick. A working agent is never touched, whatever its lane record says;
# the sweep gets it on a later tick once it actually stops. Queued lanes are
# left to the dispatch-time leftover close, which logs the same intent.
reap_finished_panes() {
  local name astatus pane n rec_status
  while IFS=$'\t' read -r name astatus pane; do
    [ -n "$name" ] || continue
    [ -n "$pane" ] || continue
    [ "$astatus" = "working" ] && continue
    n="$(sed -nE 's/^fleet-(lane|qa|fix|rescue)-([0-9]+).*$/\2/p' <<<"$name")"
    [ -n "$n" ] || continue
    rec_status=""
    [ -f "$TASKS_DIR/$n.json" ] && rec_status="$(jq -r '.status // ""' "$TASKS_DIR/$n.json" 2>/dev/null)"
    case "$rec_status" in
      done | blocked | "")
        fctl log "$n" "reaped the pane of finished agent $name (agent ${astatus:-unknown}, lane ${rec_status:-without a record})"
        if [ "$DRY" = "1" ]; then
          echo "DRY: herdr pane close $pane ($name)"
        else
          herdr pane close "$pane" >/dev/null 2>&1
        fi
        ;;
    esac
  done < <(herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]? | select((.name // "") | test("^fleet-(lane|qa|fix|rescue)-[0-9]")) | [.name, .agent_status // "", .pane_id // ""] | @tsv' 2>/dev/null)
}

close_named_pane() { # <agent name> — close the pane a leftover agent still holds
  local name="$1" pane
  pane="$(herdr agent list 2>/dev/null | jq -r --arg n "$name" '.result.agents[]? | select(.name == $n) | .pane_id // empty' 2>/dev/null | head -n1)"
  [ -n "$pane" ] || return 0
  if [ "$DRY" = "1" ]; then
    echo "DRY: herdr pane close $pane ($name)"
  else
    herdr pane close "$pane" >/dev/null 2>&1
  fi
}

# Move a merged lane's leftover files out of its worktree so the reap check
# can pass. Three live jams on 2026-08-25 were all this shape: a relay
# handoff note, edited progress notes, once ~764 lines of uncommitted edits
# left the worktree dirty, the reap check said KEEP every tick, and teardown
# burned all its attempts and raised the give-up alarm. Tracked edits are
# saved as a patch, untracked files moved wholesale, both under
# $STATE_DIR/salvage keyed by issue. Callers must only reach this for
# merged/done lanes (teardown_lane pins that), so nothing live is discarded.
# Detection uses diff/ls-files rather than status --porcelain: diff HEAD
# covers staged and unstaged tracked edits in one read, and ls-files
# --others --exclude-standard lists exactly the untracked-but-not-ignored
# files. Returns 0 if anything was salvaged, 1 if there was nothing to do.
salvage_worktree() { # <issue> <worktree> -> 0 salvaged something, 1 nothing to do
  local issue="$1" worktree="$2" salvage_dir stamp patch modified untracked n_mod n_untr total f dest
  salvage_dir="$STATE_DIR/salvage"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  modified="$(git -C "$worktree" diff --name-only HEAD -- 2>/dev/null)"
  untracked="$(git -C "$worktree" ls-files --others --exclude-standard 2>/dev/null)"
  [ -n "$modified" ] || [ -n "$untracked" ] || return 1
  n_mod=0
  [ -n "$modified" ] && n_mod="$(wc -l <<<"$modified")"
  n_untr=0
  [ -n "$untracked" ] && n_untr="$(wc -l <<<"$untracked")"
  total=$((n_mod + n_untr))
  patch="$salvage_dir/$issue-uncommitted-$stamp.patch"
  if [ "$DRY" = "1" ]; then
    [ -n "$modified" ] && echo "DRY: save the worktree's uncommitted diff to $patch and discard the edits"
    [ -n "$untracked" ] && echo "DRY: move $n_untr untracked file(s) from $worktree into $salvage_dir/$issue-untracked/"
  else
    mkdir -p "$salvage_dir"
    if [ -n "$modified" ]; then
      # Discard only after the patch is safely on disk; a failed save keeps
      # the edits in place and the KEEP/retry path below handles it.
      if git -C "$worktree" diff HEAD -- >"$patch" 2>/dev/null; then
        # checkout HEAD -- . resets index and working tree together, so
        # staged edits are discarded too (the patch above captured them).
        git -C "$worktree" checkout HEAD -- . 2>/dev/null || true
      else
        rm -f "$patch"
      fi
    fi
    if [ -n "$untracked" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        dest="$salvage_dir/$issue-untracked/$f"
        mkdir -p "$(dirname "$dest")"
        mv "$worktree/$f" "$dest" 2>/dev/null || true
      done <<<"$untracked"
    fi
  fi
  fctl log "$issue" "teardown: saved leftover uncommitted work to the salvage folder before cleanup ($total files)"
  return 0
}

# Stop orphaned leftover processes so the reap check can pass. Lane 1975's
# build agent started a preview dev server (pnpm dev) inside the worktree as
# its live-path proof and never shut it down; the server was reparented to
# pid 1, gate 3 of the reap check rightly said KEEP every tick, teardown
# burned all 5 attempts and raised the give-up alarm, and a human had to
# stop the server and remove the worktree by hand (2026-08-26). Only
# processes whose current directory is inside the worktree AND whose parent
# is pid 1 are touched: panes and agents always have a live supervisor
# (tmux/herdr), so the parent-pid gate cannot reach them. Callers must only
# reach this for merged/done lanes (teardown_lane pins that). Polite TERM
# only, with a bounded wait; a process that ignores it is logged and left
# for the existing KEEP/retry/alarm path -- never a hard kill.
# FLEET_PROC_ROOT exists so tests can stand in a fake /proc.
stop_orphaned_leftovers() { # <issue> <worktree>
  local issue="$1" worktree="$2" proc_root p pid cwd ppid cmd signalled="" i alive
  proc_root="${FLEET_PROC_ROOT:-/proc}"
  for p in "$proc_root"/[0-9]*; do
    [ -d "$p" ] || continue
    pid="${p##*/}"
    cwd="$(readlink "$p/cwd" 2>/dev/null || true)"
    case "$cwd" in
      "$worktree" | "$worktree"/*) ;;
      *) continue ;;
    esac
    ppid="$(awk '/^PPid:/{print $2; exit}' "$p/status" 2>/dev/null)"
    [ "$ppid" = "1" ] || continue
    cmd="$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null | cut -c1-120)"
    cmd="${cmd% }"
    act kill -TERM "$pid"
    fctl log "$issue" "teardown: asked orphaned leftover process $pid to stop (${cmd:-unknown command})"
    signalled="$signalled $pid"
  done
  [ -n "$signalled" ] || return 0
  [ "$DRY" = "1" ] && return 0
  # Bounded wait (up to ~3s) for the polite signal to land.
  for i in 1 2 3 4 5 6; do
    alive=""
    for pid in $signalled; do
      [ -d "$proc_root/$pid" ] && alive="$alive $pid"
    done
    [ -z "$alive" ] && return 0
    sleep 0.5
  done
  for pid in $signalled; do
    if [ -d "$proc_root/$pid" ]; then
      fctl log "$issue" "teardown: orphaned process $pid ignored the stop request; left alone (the reap check will keep the worktree)"
    fi
  done
}

teardown_lane() { # <issue> <record> <why> -> 0 removed (or nothing to remove), 1 kept
  local issue="$1" record="$2" why="$3" worktree verdict attempts
  worktree="$(jq -r '.worktree // empty' <<<"$record")"
  [ -n "$worktree" ] || return 0
  if [ ! -d "$worktree" ]; then
    # Already removed outside the daemon (for example by hand). Nothing to
    # tear down -- clear the record instead of retrying against nothing.
    fctl set "$issue" worktree=null
    fctl log "$issue" "teardown: worktree already gone from disk ($worktree); cleared the record"
    return 0
  fi
  attempts="$(jq -r '.teardown_attempts // 0' <<<"$record")"
  if [ "$attempts" -ge "$TEARDOWN_MAX_ATTEMPTS" ]; then
    log_if_new "$issue" "ALARM: teardown given up after $attempts tries; worktree left at $worktree (clean it by hand)"
    return 1
  fi
  # Panes first. The reap check refuses while this lane's finished agents
  # still hold shells inside the worktree -- and the old order (check, then
  # close) could therefore never pass. Once a lane reaches teardown its
  # stage says nobody may be working it (same rule as the spawn guards),
  # so every pane named for this lane is safe to close.
  close_lane_panes "$issue"
  # Orphaned leftovers next (an abandoned dev server, say), and only for a
  # lane whose work is merged or done -- the same status pin as the salvage
  # and branch-delete steps below.
  local orphan_status
  orphan_status="$(jq -r '.status // empty' <<<"$record")"
  if [ "$orphan_status" = "merging" ] || [ "$orphan_status" = "done" ]; then
    stop_orphaned_leftovers "$issue" "$worktree"
  fi
  if [ ! -x "$REPO_ROOT/scripts/worktree-reapable.sh" ]; then
    fctl log "$issue" "reap check unavailable, keeping worktree"
    return 1
  fi
  verdict="$("$REPO_ROOT/scripts/worktree-reapable.sh" "$worktree" 2>/dev/null | grep -o 'REAPABLE\|KEEP' | head -n1)"
  if [ "$verdict" != "REAPABLE" ] && [ "$DRY" != "1" ]; then
    sleep 2 # a freshly closed pane's processes can take a moment to die
    verdict="$("$REPO_ROOT/scripts/worktree-reapable.sh" "$worktree" 2>/dev/null | grep -o 'REAPABLE\|KEEP' | head -n1)"
  fi
  if [ "$verdict" != "REAPABLE" ]; then
    # KEEP usually means leftover files (relay handoff notes, edited
    # progress docs, stray uncommitted work). Teardown only ever runs for
    # merged/done lanes -- the status check here pins that, same as the
    # branch delete below -- so salvage the leftovers to the state dir and
    # retry the reap check before burning an attempt.
    local salvage_status
    salvage_status="$(jq -r '.status // empty' <<<"$record")"
    if { [ "$salvage_status" = "merging" ] || [ "$salvage_status" = "done" ]; } \
      && salvage_worktree "$issue" "$worktree"; then
      if [ "$DRY" = "1" ]; then
        # A dry salvage moves nothing, so a real re-check would still say
        # KEEP; assume it would have cleaned the tree and show the removal.
        verdict="REAPABLE"
      else
        verdict="$("$REPO_ROOT/scripts/worktree-reapable.sh" "$worktree" 2>/dev/null | grep -o 'REAPABLE\|KEEP' | head -n1)"
      fi
    fi
  fi
  if [ "$verdict" = "REAPABLE" ]; then
    act git -C "$REPO_ROOT" worktree remove "$worktree"
    # The worktree is gone; the local branch would otherwise linger forever
    # (no other code path deletes branches). Teardown only ever runs for
    # lanes whose PR merged or that are already done -- the status check
    # pins that so a future caller cannot delete a live branch. Forced
    # delete (-D) because squash merges leave the branch outside main's
    # ancestry, so -d would always refuse.
    local branch status
    branch="$(jq -r '.branch // empty' <<<"$record")"
    status="$(jq -r '.status // empty' <<<"$record")"
    if [ -n "$branch" ] && { [ "$status" = "merging" ] || [ "$status" = "done" ]; } \
      && git -C "$REPO_ROOT" show-ref --quiet --verify "refs/heads/$branch"; then
      act git -C "$REPO_ROOT" branch -D "$branch"
      fctl log "$issue" "teardown: deleted local branch $branch (merged)"
    fi
    fctl set "$issue" worktree=null
    fctl log "$issue" "teardown: $why; removed worktree $worktree and closed the lane's panes"
    return 0
  fi
  fctl set "$issue" "teardown_attempts=$((attempts + 1))"
  log_if_new "$issue" "teardown kept $worktree (reap check said KEEP); will retry next tick"
  return 1
}

handle_merging() { # <issue> <record>
  local issue="$1" record="$2"
  local pr state
  pr="$(jq -r '.pr // empty' <<<"$record")"
  [ -n "$pr" ] || return 0
  pr_merge_state "$pr" || return 0
  state="$PR_STATE"
  case "$state" in
    MERGED) ;;
    CLOSED)
      fctl set "$issue" status=blocked "blocked_reason=PR #$pr closed without merging"
      fctl log "$issue" "PR #$pr was closed without merging; parked"
      return 0
      ;;
    *)
      # Still open. A lane cannot sit here forever -- 45 minutes in, read
      # why once and either route a fix or park with the state as the
      # reason (Unit 5).
      local updated age
      updated="$(jq -r '.updated_at // empty' <<<"$record")"
      if [ -n "$updated" ]; then
        age=$((NOW_EPOCH - $(iso_to_epoch "$updated")))
        if [ "$age" -ge "$MERGING_DEADLINE_SECONDS" ]; then
          route_merge_failure "$issue" "$record" "$pr" "still merging after 45 minutes with the pull request open"
        fi
      fi
      return 0
      ;;
  esac
  teardown_lane "$issue" "$record" "PR #$pr merged" || true
  if close_out_github "$issue" "$record" "$pr"; then
    fctl set "$issue" status=done
    fctl log "$issue" "done: PR #$pr merged"
    revisit_parent_after_merge "$issue"
  fi
}

# A parked reason that means "the slice was too big": the relay-cap park, or
# an agent saying in its own words that the work does not fit one session
# (lane 1889 wrote "needs splitting", 2026-08-25). Re-slicing is real
# judgment work, not a one-word answer -- so the deputy is never offered
# RESUME for these, and handle_blocked tries the automatic re-slice first.
relay_capped_reason() { # <reason>
  grep -qiE "needs re-slice|re-sliced|needs splitting|needs to be split|too big|bigger than fits|does not fit|doesn.t fit" <<<"$1"
}

deputy_call() { # <issue> <record> <reason> <attempts already made for this reason>
  local issue="$1" record="$2" reason="$3" attempts="${4:-0}"
  local pr tier spec question ruling raw options options_text out_file
  pr="$(jq -r '.pr // empty' <<<"$record")"
  tier="$(jq -r '.tier // "routine"' <<<"$record")"
  question="You are acting as Ben's deputy for the Jarv1s fleet. Lane $issue is parked with reason: $reason. Ben's standing rule (2026-08-24): the fleet never pauses for him -- you hold his decision authority. You may decide anything Ben could have been asked, including security-tier merge sign-off, EXCEPT actions on the hard floor: touching prod (:1533); deleting or dropping user data, databases, or vault content; force-pushing or rewriting history; deleting branches or worktrees with unmerged work; disabling CI, guardrails, or required checks; exceeding the spawn budget; bypassing the live-path check; exposing secrets. If the ruling would need any of those, your only allowed answer is PARK. Prefer the reversible option when it is close. This lane's tier is $tier."
  if [ "$DRY" = "1" ]; then
    echo "DRY: $JUDGE_CMD [deputy for lane $issue: $reason]"
    return 0
  fi
  if relay_capped_reason "$reason"; then
    # Spec: a lane parked at the relay cap needs the task re-sliced, which is
    # real judgment work. The deputy's only option there is PARK -- neither
    # re-queueing it as-is nor merging half-finished work is on the table.
    options="PARK"
    options_text="PARK (leave it for Ben). This lane needs the task re-sliced, which is real judgment work, so putting it back in the queue as-is or merging it is not a choice here; the only allowed answer is PARK."
  elif [ -n "$pr" ]; then
    options="MERGE RESUME PARK"
    options_text="MERGE (enable auto-merge on the PR), RESUME (put the lane back in the queue), or PARK (leave it for Ben)"
  else
    # No pull request means MERGE means nothing. Offering it anyway made the
    # deputy rule MERGE on a PR-less lane (1889, 2026-08-25); the ruling
    # evaporated silently and forced a re-ask that flipped to PARK.
    options="RESUME PARK"
    options_text="RESUME (put the lane back in the queue) or PARK (leave it for Ben)"
  fi
  local prompt
  prompt="$question

Answer with a SINGLE first line containing exactly one word: $options_text. Only the first line is read.

Lane record:
$record

Last 20 log lines for this lane:
$(lane_log_tail "$issue")"
  out_file="$(mktemp)"
  # shellcheck disable=SC2086 # JUDGE_CMD is a command, splitting is intended
  if ! $JUDGE_CMD "$prompt" >"$out_file" 2>&1; then
    rm -f "$out_file"
    judge_command_failed_alarm
    fctl log "$issue" "deputy could not ask a ruling this tick: the judge command failed to run; lane stays parked, will retry next tick"
    return 0
  fi
  raw="$(head -n1 "$out_file" | tr -d '\r')"
  rm -f "$out_file"
  # shellcheck disable=SC2086 # options is a plain word list, splitting is intended
  ruling="$(parse_ruling "$raw" $options)"
  fctl log "$issue" "DEPUTY question: $question"
  fctl log "$issue" "DEPUTY ruling: ${ruling:-<no answer>}"
  case "$ruling" in
    MERGE)
      # Hard floor stays enforced in code: a lane parked by the live-path gate
      # cannot be merged past it, deputy or not.
      if grep -qi "code-complete, unverified" <<<"$reason"; then
        fctl log "$issue" "DEPUTY MERGE refused: merging would bypass the live-path check (hard floor); lane stays parked"
        fctl set "$issue" "deputy_reason=$reason" "deputy_answer=PARK" "deputy_attempts=$((attempts + 1))"
        return 0
      fi
      if [ -n "$pr" ]; then
        if [ "$TICK_STARVED" = "1" ]; then
          # The merge gates below need answers from GitHub, and GitHub is
          # refusing to answer this tick. Nothing is stamped, so the deputy
          # asks again next tick rather than merging ungated.
          fctl log "$issue" "DEPUTY ruled MERGE but GitHub is refusing to answer this tick, so the merge gates cannot be checked; will re-check next tick"
          return 0
        fi
        # A deputy merge is subject to every gate the normal path applies,
        # including live proof: a user-facing change must carry the anchored
        # proof comment on the PR before auto-merge may be enabled.
        spec="$(jq -r '.spec // ""' <<<"$record")"
        if is_user_facing "$spec" "$pr" && ! has_live_path_proof "$pr"; then
          fctl log "$issue" "DEPUTY MERGE refused: user-facing PR #$pr has no live-path proof comment (hard floor); lane stays parked"
          fctl set "$issue" "deputy_reason=$reason" "deputy_answer=PARK" "deputy_attempts=$((attempts + 1))"
          return 0
        fi
        if enable_auto_merge "$pr"; then
          fctl set "$issue" status=merging blocked_reason= "deputy_reason=$reason" "deputy_answer=MERGE" "deputy_attempts=$((attempts + 1))"
          fctl log "$issue" "DEPUTY applied: auto-merge enabled on PR #$pr"
          if [ "$tier" = "security" ]; then
            fctl log "$issue" "DEPUTY security merge sign-off: PR #$pr approved by the deputy; flag at the top of the morning board"
          fi
        else
          # Same routing as a normal merge failure: behind gets a branch
          # update, a real conflict gets a fix agent, anything else parks
          # with the command's own error text.
          fctl set "$issue" "deputy_reason=$reason" "deputy_answer=MERGE" "deputy_attempts=$((attempts + 1))"
          fctl log "$issue" "DEPUTY ruled MERGE but enabling auto-merge failed; routing the failure the same way as a normal merge"
          route_merge_failure "$issue" "$record" "$pr" "${MERGE_ERR:-auto-merge was refused and gave no reason}"
        fi
      else
        # Belt over the braces above: even if MERGE slips through for a
        # PR-less lane, count it as no ruling instead of dropping it.
        fctl log "$issue" "DEPUTY ruled MERGE but this lane has no pull request; treating it as no ruling"
        fctl set "$issue" "deputy_reason=$reason" deputy_answer= "deputy_attempts=$((attempts + 1))"
      fi
      ;;
    RESUME)
      fctl set "$issue" status=queued blocked_reason= question= questionAskedAt= deputy_reason= deputy_answer= deputy_attempts=0
      fctl log "$issue" "DEPUTY applied: lane returned to the queue"
      ;;
    PARK)
      fctl set "$issue" "deputy_reason=$reason" "deputy_answer=PARK" "deputy_attempts=$((attempts + 1))"
      fctl log "$issue" "DEPUTY applied: lane stays parked"
      ;;
    *)
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3 ]; then
        local final_reason="$reason -- the deputy could not produce a clear ruling after 3 tries; last answer: ${raw:-<no answer>}"
        fctl set "$issue" "blocked_reason=$final_reason" "deputy_reason=$final_reason" "deputy_answer=PARK" "deputy_attempts=$attempts"
        fctl log "$issue" "DEPUTY gave up after 3 tries with no clear ruling; parked with the model's last answer"
      else
        fctl set "$issue" "deputy_reason=$reason" deputy_answer= "deputy_attempts=$attempts"
        fctl log "$issue" "DEPUTY answer did not parse; will ask again next tick ($attempts of 3 tries used)"
      fi
      ;;
  esac
}

handle_blocked() { # <issue> <record>
  local issue="$1" record="$2"
  local reason entry entry_age deputy_reason deputy_answer deputy_attempts transient_cleared reslice_failures
  local reply_file reply_text reply_flat first_word pr spec asked_epoch asked_iso overridden_floor
  reason="$(jq -r '.blocked_reason // "no reason recorded"' <<<"$record")"
  # The phone ping moved below (Ben's standing rule, 2026-08-24): the deputy
  # rules first, and Ben only hears about a lane once even the deputy has
  # parked it. A reply from him still beats everything.

  # A reply from Ben always does something -- it is never just filed and
  # left. Fixed first words, no model between his words and the action
  # (Ben's ruling, 2026-08-23): "resume" re-queues the lane, "merge" enables
  # auto-merge, and anything else leaves the lane parked but stamps the
  # record so the board surfaces it for a human to read. Ben's own "merge"
  # overrides the two live-path floors (his explicit ruling, 2026-08-26,
  # after issue 1949 needed a hand bypass): he accepts the risk because he
  # tests in production himself. This override is reply-path only; the
  # deputy's merge stays behind both floors.
  asked_epoch=0
  asked_iso="$(jq -r '.questionAskedAt // empty' <<<"$record")"
  [ -n "$asked_iso" ] && asked_epoch="$(date -d "$asked_iso" +%s 2>/dev/null || echo 0)"
  reply_file="$(needs_ben_reply_file "$issue" "$asked_epoch")"
  if [ -n "$reply_file" ]; then
    reply_text="$(cat "$reply_file" 2>/dev/null)"
    reply_flat="$(tr '\n' ' ' <<<"$reply_text" | sed -E 's/[[:space:]]+/ /g; s/ $//')"
    first_word="$(reply_first_word "$reply_text")"
    case "$first_word" in
      resume)
        act mv "$reply_file" "$reply_file.handled"
        fctl set "$issue" status=queued blocked_reason= question= questionAskedAt= deputy_reason= deputy_answer= "deputy_attempts=0"
        fctl log "$issue" "Ben replied 'resume': lane is back in the queue"
        ;;
      merge)
        pr="$(jq -r '.pr // empty' <<<"$record")"
        if [ -z "$pr" ] || [ "$pr" = "null" ]; then
          act mv "$reply_file" "$reply_file.handled"
          fctl log "$issue" "Ben replied 'merge' but this lane has no pull request yet; nothing to merge"
        elif [ "$TICK_STARVED" = "1" ]; then
          # Enabling the merge needs answers from GitHub, and GitHub is
          # refusing to answer this tick. The reply is left un-handled so it
          # is acted on next tick.
          :
        else
          # Ben's "merge" overrides the two live-path floors (his explicit
          # ruling, 2026-08-26). Work out which floor, if any, would have
          # refused, so the override is logged loudly by name. The deputy's
          # MERGE path above keeps both refusals.
          overridden_floor=""
          spec="$(jq -r '.spec // ""' <<<"$record")"
          if grep -qi "code-complete, unverified" <<<"$reason"; then
            overridden_floor="the code-complete-unverified park (live-path check)"
          elif is_user_facing "$spec" "$pr" && ! has_live_path_proof "$pr"; then
            overridden_floor="the missing live-path proof comment on user-facing PR #$pr"
          fi
          if enable_auto_merge "$pr"; then
            act mv "$reply_file" "$reply_file.handled"
            fctl set "$issue" status=merging blocked_reason=
            if [ -n "$overridden_floor" ]; then
              fctl log "$issue" "OVERRIDE: merge ran on Ben's explicit 'merge' instruction (his 2026-08-26 ruling) with the live-path proof skipped; floor overridden: $overridden_floor"
            fi
            fctl log "$issue" "Ben replied 'merge': auto-merge enabled on PR #$pr"
          else
            # Same routing as a normal merge failure: behind gets a branch
            # update, a real conflict gets a fix agent, anything else parks
            # with the command's own error text.
            act mv "$reply_file" "$reply_file.handled"
            fctl log "$issue" "Ben replied 'merge' but enabling auto-merge failed; routing the failure the same way as a normal merge"
            route_merge_failure "$issue" "$record" "$pr" "${MERGE_ERR:-auto-merge was refused and gave no reason}"
          fi
        fi
        ;;
      *)
        act mv "$reply_file" "$reply_file.handled"
        fctl set "$issue" "blocked_reason=Ben replied, needs reading: ${reply_flat:-<empty reply>}"
        fctl log "$issue" "Ben replied, but not with resume or merge; lane stays parked, stamped so the board shows it needs reading"
        ;;
    esac
    return 0
  fi

  # A lane parked as "re-sliced ..." is finished: the remaining work lives in
  # the follow-up issue named in the reason, and any open PR just waits for
  # review. Nothing to decide, nobody to ring. (Ben's reply above still wins
  # if he sends one.)
  case "$reason" in "re-sliced "*) return 0 ;; esac

  # An agent that parks its own lane because the work does not fit one
  # session gets the same treatment as the relay cap: re-slice automatically,
  # whatever words it used (lane 1889 wrote "needs splitting" and sat waiting
  # for Ben, 2026-08-25). One attempt only -- the stamp stops a model-call
  # loop; a failed attempt falls through to the deputy and then Ben.
  if relay_capped_reason "$reason"; then
    if [ "$(jq -r '.reslice_attempted // 0' <<<"$record")" -eq 0 ]; then
      # The attempt stamp lands only on a real answer: success (rc 0) or the
      # chain guard's final refusal (rc 2). A transient failure (rc 1: judge
      # command down, issue creation refused) leaves the stamp clear and
      # counts a failure instead, so one bad moment does not kill
      # auto-splitting forever; after 3 failures the deputy and then Ben
      # take over.
      reslice_failures="$(jq -r '.reslice_failures // 0' <<<"$record")"
      if [ "$reslice_failures" -lt 3 ]; then
        auto_reslice "$issue" "$record"
        case $? in
          0)
            fctl set "$issue" reslice_attempted=1
            return 0
            ;;
          2)
            # Slicing again is forbidden; Ben's standing answer is resume
            # (2026-08-25), so un-park the lane instead of ringing anyone.
            fctl set "$issue" reslice_attempted=1 status=building relay_cap_waived=1 blocked_reason= question= questionAskedAt= deputy_reason= deputy_answer= deputy_attempts=0
            fctl log "$issue" "cannot be re-sliced again; resuming on Ben's standing 'resume'"
            return 0
            ;;
        esac
        reslice_failures=$((reslice_failures + 1))
        fctl set "$issue" "reslice_failures=$reslice_failures"
        if [ "$reslice_failures" -lt 3 ]; then
          fctl log "$issue" "could not re-slice this parked lane automatically (failure $reslice_failures of 3); falling back to the deputy, trying the re-slice again next tick"
        else
          fctl log "$issue" "could not re-slice this parked lane automatically after 3 tries; giving up on re-slicing and falling back to the deputy"
        fi
      fi
    fi
  fi

  # Deputy off is the one case where Ben is the only judge left: ping him.
  if [ "$DEPUTY_ACTIVE" != "1" ]; then
    ensure_needs_ben "$issue" "$reason"
    return 0
  fi

  # Every deputy outcome for a given parked reason -- including PARK and a
  # ruling that would not parse -- is stamped on the record, so the same
  # question is never re-asked while the reason stays the same. A changed
  # reason is a new situation and gets one new call. A stamped PARK (or a
  # deputy that gave up) is terminal: only then does Ben's phone hear about
  # the lane, with the reply instructions attached.
  deputy_reason="$(jq -r '.deputy_reason // ""' <<<"$record")"
  deputy_answer="$(jq -r '.deputy_answer // ""' <<<"$record")"
  deputy_attempts="$(jq -r '.deputy_attempts // 0' <<<"$record")"
  # A transient park cause clears on its own (the budget window resets,
  # memory frees up, the terminal manager comes back). Once it has cleared,
  # the deputy's stamped ruling describes a world that no longer exists:
  # clear the stamps and ask once more -- same shape as the judge's
  # held-RESTART rule above (world-changed reset).
  if [ "$deputy_reason" = "$reason" ]; then
    transient_cleared=""
    case "$reason" in
      "spawn budget exhausted")       budget_available && transient_cleared=1 ;;
      "free memory below the floor")  memory_ok && transient_cleared=1 ;;
      "terminal manager unreachable") [ "$TERMINAL_MANAGER_DOWN" != "1" ] && transient_cleared=1 ;;
    esac
    if [ -n "$transient_cleared" ]; then
      fctl set "$issue" deputy_reason= deputy_answer= deputy_attempts=0
      fctl log "$issue" "the transient cause that parked this lane ($reason) has cleared; asking the deputy once more"
      deputy_reason="" deputy_answer="" deputy_attempts=0
    fi
  fi
  if [ "$deputy_reason" = "$reason" ]; then
    case "$deputy_answer" in
      MERGE|RESUME) return 0 ;;
      PARK)
        ensure_needs_ben "$issue" "$reason"
        return 0
        ;;
    esac
    if [ "$deputy_attempts" -ge 3 ]; then
      ensure_needs_ben "$issue" "$reason"
      return 0
    fi
  else
    deputy_attempts=0
  fi
  deputy_call "$issue" "$record" "$reason" "$deputy_attempts"
}

handle_done() { # <issue> <record>
  # A done lane may still hold its worktree and panes: teardown before the
  # fix landed, a KEEP verdict at merge time, or the issue-closed shortcut
  # (which never ran teardown at all). Sweep the loose end here.
  local issue="$1" record="$2"
  teardown_lane "$issue" "$record" "lane already done" || true
}

# --- main loop -------------------------------------------------------------------

# One pass over the whole log builds the per-issue summary every helper
# below reads; without this each lane re-read the file dozens of times.
log_map_build

# Keep the needs-ben folders small so the per-lane grep scans stay cheap;
# handled and long-dead files move to archive/, never deleted.
needs_ben_archive_sweep

# The terminal manager (herdr) has to be reachable for any agent to be
# started at all -- a down terminal manager means every spawn this tick
# would fail the same way. Checked once, here, so that shows up as one
# fleet-level alarm instead of a storm of per-lane spawn failures below.
TERMINAL_MANAGER_DOWN=0
if ! herdr agent list >/dev/null 2>&1; then
  TERMINAL_MANAGER_DOWN=1
  fctl log fleet "ALARM: the terminal manager (herdr) is not reachable; no agent can be started this tick. Check it is running (see the runbook) before anything else."
fi

# See if memory is already tight, even before anything tries to spawn.
memory_low_warning

# Idle backoff: once every lane is done or parked and there is nothing new
# to pick up, GitHub is polled every tenth tick instead of every tick, and
# a "run complete" line is written for the board. This never touches the
# daemon's own timer -- a program that switches off its own supervision
# cannot be restarted by that supervision; the real stop is a human action
# (the STOP file, or later the viewer's end-run button).
IDLE_TICK_FILE="$STATE_DIR/.idle-tick-count"
run_all_finished() { # 0 if every lane record is done or blocked, and at least one record exists
  local f any=0
  for f in "$TASKS_DIR"/*.json; do
    [ -f "$f" ] || continue
    any=1
    case "$(jq -r '.status // ""' "$f" 2>/dev/null)" in
      done|blocked) ;;
      *) return 1 ;;
    esac
  done
  [ "$any" = "1" ]
}

RUN_COMPLETE=0
if run_all_finished; then
  RUN_COMPLETE=1
  idle_ticks=0
  [ -f "$IDLE_TICK_FILE" ] && idle_ticks="$(cat "$IDLE_TICK_FILE" 2>/dev/null)"
  case "$idle_ticks" in '' | *[!0-9]*) idle_ticks=0 ;; esac
  idle_ticks=$((idle_ticks + 1))
  echo "$idle_ticks" > "$IDLE_TICK_FILE"
  if [ $((idle_ticks % 10)) -eq 1 ]; then
    intake
    if [ "$idle_ticks" = "1" ]; then
      fctl log fleet "run complete: every lane is done or parked and intake found nothing new; checking GitHub every tenth tick from here, not every tick"
    fi
  fi
else
  rm -f "$IDLE_TICK_FILE"
  # Intake first: pick up new Ready / In Progress task issues from the board.
  intake
fi

# Live lanes for the dispatch cap: anything between queued and done/blocked.
LIVE_LANES=0
for f in "$TASKS_DIR"/*.json; do
  [ -f "$f" ] || continue
  case "$(jq -r '.status // ""' "$f" 2>/dev/null)" in
    building|pr-open|ci-red|qa|qa-red|qa-green|qa-too-big|merging) LIVE_LANES=$((LIVE_LANES + 1)) ;;
  esac
done

for f in "$TASKS_DIR"/*.json; do
  [ -f "$f" ] || continue
  record="$(cat "$f")"
  issue="$(jq -r '.issue // empty' <<<"$record")"
  status="$(jq -r '.status // empty' <<<"$record")"
  [ -n "$issue" ] || continue
  [ -n "$status" ] || continue

  # A paused lane is skipped entirely: no dispatch, no dead-lane check, no
  # relay park. A paused agent's record goes quiet on purpose, which is
  # exactly the signature the dead-lane check hunts for -- so the skip must
  # come before every other rule. Unpausing (paused=false) puts the lane
  # straight back into the normal flow; if its agent died while paused, the
  # dead-lane path picks it up on the next tick.
  paused="$(jq -r '.paused // false' <<<"$record")"
  if [ "$paused" = "true" ]; then
    continue
  fi

  # A pickup board move that GitHub rate-limited at dispatch left a note on
  # the record; retry it here, whatever state the lane has reached since.
  if [ -n "$(jq -r '.board_move_pending // empty' <<<"$record")" ]; then
    retry_board_pickup "$issue"
  fi

  # Relay rule: two relays means the task was sliced too big. Re-slice it
  # automatically (Ben's call, 2026-08-24). When slicing again is forbidden
  # (the lane is already a re-slice), resume instead of parking -- Ben's
  # standing answer is "resume", every time (2026-08-25). Park and ask only
  # on a real failure (unknown repo, issue creation refused).
  relays="$(jq -r '.relays // 0' <<<"$record")"
  if [ "$relays" -ge 2 ] && [ "$status" != "blocked" ] && [ "$status" != "done" ] \
    && [ "$(jq -r '.relay_cap_waived // 0' <<<"$record")" != "1" ]; then
    auto_reslice "$issue" "$record"
    case $? in
      0) continue ;;
      2)
        fctl set "$issue" relay_cap_waived=1
        fctl log "$issue" "relayed $relays times and cannot be re-sliced again; continuing on Ben's standing 'resume'"
        ;;
      *)
        fctl set "$issue" status=blocked "blocked_reason=needs re-slice"
        fctl log "$issue" "relayed $relays times; parked with reason: needs re-slice"
        continue
        ;;
    esac
  fi

  case "$status" in
    queued)   handle_queued "$issue" "$record" ;;
    building) handle_building "$issue" "$record" ;;
    pr-open)  handle_pr_open "$issue" "$record" ;;
    ci-red)   handle_ci_red "$issue" "$record" ;;
    qa)       handle_qa "$issue" "$record" ;;
    qa-red)   handle_qa_red "$issue" "$record" ;;
    qa-green) handle_qa_green "$issue" "$record" ;;
    qa-too-big) handle_qa_too_big "$issue" "$record" ;;
    merging)  handle_merging "$issue" "$record" ;;
    blocked)  handle_blocked "$issue" "$record" ;;
    done)     handle_done "$issue" "$record" ;;
    *)        fctl log "$issue" "unknown status '$status'; skipped" ;;
  esac
done

# Sweep the windows of finished agents before the alarm check.
reap_finished_panes

# The stillness alarm: cause-blind, cheap, and the last line of defence. If
# any lane in a state that is supposed to be moving on its own (waiting on
# checks, in review, merging) has gone a full hour with no record change and
# no log line, something is stuck -- whether or not this tick knows why. It
# does not park anything; it only makes sure a silent failure still leaves a
# trace by morning. One line, regardless of how many lanes are stale.
STILLNESS_STALE_SECONDS=$((60 * 60))
stillness_any=0
for f in "$TASKS_DIR"/*.json; do
  [ -f "$f" ] || continue
  st="$(jq -r '.status // ""' "$f" 2>/dev/null)"
  case "$st" in building | pr-open | qa | merging | ci-red | qa-red | qa-green | qa-too-big) ;; *) continue ;; esac
  lane_issue="$(jq -r '.issue // empty' "$f" 2>/dev/null)"
  lane_updated="$(jq -r '.updated_at // empty' "$f" 2>/dev/null)"
  [ -n "$lane_updated" ] || continue
  record_age=$((NOW_EPOCH - $(iso_to_epoch "$lane_updated")))
  [ "$record_age" -ge "$STILLNESS_STALE_SECONDS" ] || continue
  last_log_age=999999999
  last_log_ts="${LOGMAP_TS[$lane_issue]:-}"
  [ -n "$last_log_ts" ] && last_log_age=$((NOW_EPOCH - $(iso_to_epoch "$last_log_ts")))
  [ "$last_log_age" -ge "$STILLNESS_STALE_SECONDS" ] || continue
  stillness_any=1
done
if [ "$stillness_any" = "1" ]; then
  fctl log fleet "ALARM: stillness -- one or more lanes in a moving state (building, waiting on checks, in review, under repair after a red check or review, or merging) have gone a full hour with no record change and no log line"
fi

# Refresh Ben's morning view.
fctl board

exit 0
