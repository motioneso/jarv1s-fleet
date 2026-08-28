#!/usr/bin/env bash
# Lane watchdog: watches every pane in the fleet's agents tab for a wedged agent.
# Generalised from the coordinator watchdog (~/Jarv1s/scripts/ops/coordinator-watchdog.sh),
# which only watches one pane and only nudges. This one watches every fleet lane's pane,
# escalates to actually stopping an agent, and never kills on a quiet pane alone: it
# looks at the real process underneath before the third strike is allowed to act.
# Spec: docs/2026-08-23-fleet-viewer-and-watchdog-design.md, "Unit 8: the lane watchdog,
# corrected". Runs as a systemd oneshot on its own one-minute timer, alongside tick.sh.
#
# FLEET_DRY_RUN=1 prints every externally-visible action (a nudge into a pane, stopping
# an agent, a lane-record log write) as "DRY: <command>" instead of running it. Read-only
# queries (herdr tab list, herdr agent list, herdr pane process-info) still run, so the
# same PATH-shimmed fixtures used by tick.sh's tests can drive this script too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${JARV1S_FLEET_STATE:-$HOME/.local/state/jarv1s-fleet}"
TASKS_DIR="$STATE_DIR/tasks"
DRY="${FLEET_DRY_RUN:-0}"
NOW_EPOCH="$(date +%s)"

WATCHDOG_STATE_FILE="$STATE_DIR/.watchdog-state.json"

# Ben's rulings, 2026-08-23: 15-minute quiet periods, two nudges, then (only with the
# process check confirming truly flat CPU) a stop. A 3-hour backstop catches the
# opposite wedge -- a genuine infinite loop burning CPU while nothing visible changes.
# Do not reopen either number without a live incident that contradicts the reasoning
# in the design doc.
NUDGE_INTERVAL_SECONDS=$((15 * 60))
BACKSTOP_SECONDS=$((3 * 60 * 60))

# The work-based quiet signal (added after the 2026-08-25 incident: an agent idle at
# its interactive prompt kept repainting a clock in its status line, so the pane
# revision and CPU ticks moved every pass, quiet_since reset forever, and the
# watchdog never nudged an agent that had done nothing for over an hour). If a lane
# in a moving state has had no record update and no log line for this long, its
# agent counts as quiet regardless of pane or CPU movement, and the same
# nudge/nudge/process-checked-stop ladder engages. A nudge that wakes the agent
# makes it log or update its record, which resets this signal naturally.
WORK_QUIET_SECONDS=$((30 * 60))

# --- GitHub starvation: a blocked world is not a wedged agent ---------------------
#
# Live 2026-08-27: the shared hourly GitHub allowance ran out, every lane blocked
# waiting on GitHub, and the watchdog read the resulting silence as stalled agents
# and nudged one of them. That lane was fine -- it opened its pull request at
# 03:00:18 UTC, eleven minutes after the allowance reset at 02:49. So while the
# fleet is starved of GitHub answers, no quiet-based nudge or stop may fire, and
# the starved seconds are subtracted from the quiet clocks afterwards, so an agent
# gets its full quiet allowance from the moment GitHub starts answering again
# rather than being nudged instantly because the outage used the allowance up.
#
# The window is read from the two fleet-level log lines that mark it. tick.sh
# writes the alarm, with a varying reason in brackets, hence prefix matching. The
# daemon writes the all-clear; it may not appear in the log at all yet, and the
# code below must behave with no all-clear ever present.
STARVE_ALARM_PREFIX="ALARM: GitHub is refusing to answer"
STARVE_CLEAR_MESSAGE="GitHub is answering again; the allowance has reset"

# Ceiling on how long a starvation alarm may speak for the present. GitHub's
# allowance window is one hour, so an alarm older than that cannot still describe
# now: either the allowance reset and the all-clear was never written (lost line,
# or a tick daemon that predates the all-clear), or the fleet stopped ticking.
# Without the ceiling one stray alarm would hold every lane's quiet clock forever
# and the watchdog would never nudge anything again.
STARVE_CEILING_SECONDS=$((60 * 60))

# The most recent starvation window, filled in below from the log: seconds between
# STARVE_START and STARVE_END count as "the fleet was waiting on GitHub". Zeroed
# here so the helpers are safe even when the log cannot be read.
STARVE_START=0
STARVE_END=0
GITHUB_STARVED=0
GITHUB_HOLD_NOTED=0
# Reserved key in the watchdog's own state file recording which outage the "clock
# on hold" line was already logged for, so it is written once per outage rather
# than once a minute for every lane. It can never collide with an agent row: every
# watched agent is named fleet-something.
STARVE_NOTE_KEY="_github_starvation"

# How much of the time since <epoch> the fleet spent waiting on GitHub.
starved_seconds_since() { # <epoch> -> seconds
  local from="$1" begin
  [ "$STARVE_END" -gt "$STARVE_START" ] || { echo 0; return 0; }
  begin="$STARVE_START"
  [ "$from" -gt "$begin" ] && begin="$from"
  if [ "$STARVE_END" -gt "$begin" ]; then
    echo $((STARVE_END - begin))
  else
    echo 0
  fi
}

AGENT_TAB_LABEL="${FLEET_AGENT_TAB:-Fleet Agents}"

[ -f "$STATE_DIR/STOP" ] && exit 0
[ -d "$TASKS_DIR" ] || exit 0

if command -v fleetctl >/dev/null 2>&1; then
  FLEETCTL=(fleetctl)
else
  FLEETCTL=(node "$SCRIPT_DIR/fleetctl.mjs")
fi

fctl() {
  if [ "$DRY" = "1" ]; then
    echo "DRY: fleetctl $*"
  else
    "${FLEETCTL[@]}" "$@"
  fi
}

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

# Same whole-token fleet agent naming patterns tick.sh uses (unit 7): fleet-lane-N,
# fleet-qa-N, fleet-fix-N, fleet-rescue-N, and their round/retry suffixes. Echoes the
# issue number if it matches, nothing otherwise -- a pane with no fleet agent, or an
# agent named for something else entirely, is ignored.
agent_issue_number() { # <agent name> -> issue number, or empty
  local name="$1"
  if [[ "$name" =~ ^fleet-(lane|qa|fix|rescue)-([0-9]+)(-(ci|qa|merge))?(-r[0-9]+)?(-retry|-chunked)?$ ]]; then
    echo "${BASH_REMATCH[2]}"
  fi
}

agent_tab_ids() { # -> JSON array of every fleet tab id ("Fleet Agents", "Fleet Agents 2", ...)
  # tick.sh names spill tabs "$AGENT_TAB_LABEL <n>" once a tab fills (4 panes);
  # watching only the first tab left every spilled agent unwatched.
  herdr tab list 2>/dev/null |
    jq -c --arg label "$AGENT_TAB_LABEL" \
      '[.result.tabs[]? | select((.label // "") == $label or ((.label // "") | startswith($label + " "))) | .tab_id]' 2>/dev/null
}

# The terminal manager's own view of the pane's top process -- the seam the process
# check starts from. Empty means "could not find it", handled as fail-safe by the
# caller, never as zero.
pane_top_pid() { # <pane id> -> pid, or empty if unavailable
  local pane="$1" out pid
  out="$(herdr pane process-info --pane "$pane" 2>/dev/null)"
  [ -n "$out" ] || return 0
  pid="$(jq -r '.result.process_info.foreground_process_group_id // empty' <<<"$out" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  echo "$pid"
}

# Where the system's process table is read from. Only for testing (fixture
# directories laid out like /proc/<pid>/stat); leave alone in production. Mirrors
# tick.sh's FLEET_MEMINFO seam for reading free memory.
PROC_DIR="${FLEET_PROC_DIR:-/proc}"

# Every pid whose ppid (as read from the fixture-or-real process table) is the given
# pid. Scans the whole table -- fine at the process counts a dev box or CI box runs.
children_of() { # <pid> -> child pids, one per line
  local ppid="$1" f rest fields unavailable=0
  for f in "$PROC_DIR"/[0-9]*/stat; do
    [ -f "$f" ] || continue
    rest="$(cat "$f" 2>/dev/null)" || { unavailable=1; continue; }
    rest="${rest##*) }"
    read -r -a fields <<<"$rest"
    case "${fields[1]:-}:${fields[11]:-}:${fields[12]:-}" in
      *[!0-9:]*|:*|*::*) unavailable=1; continue ;;
    esac
    if [ "${fields[1]:-}" = "$ppid" ]; then
      basename "$(dirname "$f")"
    fi
  done
  [ "$unavailable" = "0" ]
}

# Total CPU ticks (utime+stime) used by a process and every descendant it has spawned,
# summed across the whole family. Empty means the table could not be read or the
# process was not found -- the caller must treat that as "unavailable", never as zero.
# Why total ticks compared between one-minute passes, not a single snapshot: a single
# instant only catches a process if it happens to be on the CPU at that exact moment,
# so a busy-but-bursty process can read as idle. The ticks counter only ever goes up,
# so a between-passes comparison cannot be fooled that way.
process_family_cpu_ticks() { # <root pid> -> total ticks, or empty
  local root="$1" stat_file rest fields utime stime total=0 found=0 children
  local -a queue=("$root")
  [ -d "$PROC_DIR" ] || return 0
  while [ "${#queue[@]}" -gt 0 ]; do
    local pid="${queue[0]}"
    queue=("${queue[@]:1}")
    stat_file="$PROC_DIR/$pid/stat"
    [ -f "$stat_file" ] || continue
    rest="$(cat "$stat_file" 2>/dev/null)" || return 0
    # Fields after the comm field's closing paren are space-separated and fixed in
    # order; comm itself may contain spaces or parens, so split on the LAST ")".
    rest="${rest##*) }"
    read -r -a fields <<<"$rest"
    # 0-indexed from "state": state(0) ppid(1) pgrp(2) session(3) tty_nr(4) tpgid(5)
    # flags(6) minflt(7) cminflt(8) majflt(9) cmajflt(10) utime(11) stime(12) ...
    utime="${fields[11]:-}"
    stime="${fields[12]:-}"
    case "$utime:$stime" in '' | *[!0-9:]* | *:*:*) return 0 ;; esac
    total=$((total + utime + stime))
    found=1
    children="$(children_of "$pid")" || return 0
    while IFS= read -r child; do
      [ -n "$child" ] && queue+=("$child")
    done <<<"$children"
  done
  [ "$found" = "1" ] || return 0
  echo "$total"
}

# A lane's worktree can also contain a process that outlived its pane and was
# reparented to pid 1. Such a process is real work and protects the lane from
# a stop, but the session runtime itself is only furniture. Codex commonly
# appears as node/codex under herdr or bwrap; those wrappers must not look like
# orphaned worktree work. An unrecognised or unreadable process is unsafe to
# classify, so the caller treats status 2 as protected.
session_runtime_process() { # <comm> <parent comm> -> 0 when session furniture
  local comm="$1" parent="$2"
  case "$comm" in
    bwrap) return 0 ;;
    claude) case "$parent" in bwrap | herdr | tmux*) return 0 ;; esac ;;
    codex) case "$parent" in bwrap | herdr | node | tmux*) return 0 ;; esac ;;
    node) case "$parent" in bwrap | herdr | tmux*) return 0 ;; esac ;;
    bash) case "$parent" in tmux*) return 0 ;; esac ;;
  esac
  return 1
}

worktree_orphan_state() { # <worktree> <session pid> -> 0 orphan, 1 none, 2 unverifiable
  local worktree="$1" session_pid="$2" entry pid cwd comm ppid pcomm
  worktree="$(readlink -f "$worktree" 2>/dev/null)"
  [ -n "$worktree" ] || return 2
  for entry in "$PROC_DIR"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid="${entry##*/}"
    [ "$pid" = "$$" ] && continue
    cwd="$(readlink "$entry/cwd" 2>/dev/null)" || return 2
    case "$cwd" in "$worktree" | "$worktree"/*) ;; *) continue ;; esac
    comm="$(cat "$entry/comm" 2>/dev/null)" || return 2
    ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "$entry/status" 2>/dev/null)"
    case "$ppid" in '' | *[!0-9]*) return 2 ;; esac
    pcomm=""
    if [ "$ppid" != "1" ]; then
      pcomm="$(cat "$PROC_DIR/$ppid/comm" 2>/dev/null)" || return 2
    fi
    [ "$pid" = "$session_pid" ] && continue
    session_runtime_process "$comm" "$pcomm" && continue
    return 0
  done
  return 1
}

# --- the watchdog's own small state file, keyed by agent name --------------------
#
# Read once at the top, one field written per agent per pass, written out once at
# the end -- reading the count from its own file, not re-scanning the fleet log,
# keeps this cheap. Only agents seen this pass are carried into the new file, so it
# never grows with agents that finished long ago.

WATCHDOG_STATE="{}"
if [ -f "$WATCHDOG_STATE_FILE" ]; then
  WATCHDOG_STATE="$(cat "$WATCHDOG_STATE_FILE" 2>/dev/null)"
  jq -e . >/dev/null 2>&1 <<<"$WATCHDOG_STATE" || WATCHDOG_STATE="{}"
fi
NEW_STATE="{}"

# This script intentionally has no lease/CAS protocol of its own. A complete
# version needs tick/fleetctl to expose one atomic interface: claim(issue,
# expected updated_at, expected active worker, purpose) -> opaque lease token;
# nudge/close/log(issue, lease token) must reject a stale token; and every tick
# write must invalidate or preserve that token under the same compare-and-set.
# Until that exists, this watchdog only acts on the worker named by the record
# it read and treats mismatches as unverified rather than guessing ownership.

state_get() { # <agent name> <field> -> value, or empty
  jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // empty' <<<"$WATCHDOG_STATE" 2>/dev/null
}

# Carries one agent's row forward into the state file being built for this pass.
# content_since is the moment the pane's content (its revision) last changed --
# the clock the 3-hour backstop runs on. It is separate from quiet_since because
# a "working" self-report backed by CPU movement resets the quiet clock but must
# never reset this one: an infinite loop reports working and burns CPU forever
# while its content never changes, and the backstop exists for exactly that.
state_save() { # <agent name> <quiet_since> <nudge_count> <revision> <cpu_ticks> <cpu_pid> <content_since>
  NEW_STATE="$(jq \
    --arg n "$1" --argjson quiet_since "$2" --argjson nudge_count "$3" \
    --arg revision "$4" --arg cpu_ticks "$5" --arg cpu_pid "$6" \
    --argjson content_since "$7" \
    '.[$n] = {quiet_since: $quiet_since, nudge_count: $nudge_count, revision: $revision, cpu_ticks: $cpu_ticks, cpu_pid: $cpu_pid, content_since: $content_since}' \
    <<<"$NEW_STATE")"
}

# --- nudging and stopping ---------------------------------------------------------

send_nudge() { # <issue> <agent name> <nudge number: 1 or 2>
  local issue="$1" name="$2" n="$3"
  local msg="Watchdog: this pane has shown no visible progress for a while. If you are stuck, waiting on something, or finished and forgot to report it, say so now; otherwise keep going. This is nudge $n of 2 before the watchdog stops this session."
  act herdr agent prompt "$name" "$msg" >/dev/null
  fctl log "$issue" "watchdog: sent nudge $n of 2 to $name for looking quiet"
}

send_nudge_unavailable() { # <issue> <agent name>
  local issue="$1" name="$2"
  local msg="Watchdog: this pane has shown no visible progress for a while, but the watchdog could not check whether the underlying work is actually still running, so it is not stopping anything yet. If you are stuck, say so now."
  act herdr agent prompt "$name" "$msg" >/dev/null
  fctl log "$issue" "watchdog: process check unavailable for $name (could not read the process table, find the pane's process, or compare against a reading from a minute ago); sent a nudge instead of stopping, will check again next pass"
}

# Logged once per outage, at fleet level, the first time a lane's quiet clock is
# held. Not per lane and not per pass: at one pass a minute across every lane that
# would flood the log for the length of the outage.
note_github_hold() {
  [ "$GITHUB_HOLD_NOTED" = "1" ] && return 0
  GITHUB_HOLD_NOTED=1
  local noted
  noted="$(jq -r --arg k "$STARVE_NOTE_KEY" '.[$k].noted_for // empty' <<<"$WATCHDOG_STATE" 2>/dev/null)"
  [ "$noted" = "$STARVE_START" ] && return 0
  fctl log fleet "watchdog: lanes are quiet because GitHub is not answering, not because their agents are stuck; the quiet clock is on hold until the allowance resets"
}

stop_agent() { # <issue> <agent name> <pane id> <plain-English reason, with CPU numbers where relevant>
  local issue="$1" name="$2" pane="$3" reason="$4"
  act herdr pane close "$pane" >/dev/null
  fctl log "$issue" "watchdog: stopped $name -- $reason"
}

# --- one pass over every fleet agent in every fleet tab ----------------------------

TAB_IDS="$(agent_tab_ids)"
[ -n "$TAB_IDS" ] || TAB_IDS="[]"
if [ "$TAB_IDS" != "[]" ]; then
  AGENTS_JSON="$(herdr agent list 2>/dev/null)"
  if [ -n "$AGENTS_JSON" ]; then
    # One pass over the fleet log builds a per-issue latest-timestamp map for the
    # work-based quiet signal: log.jsonl is read once per watchdog pass (box rule),
    # never once per agent. Unparseable lines are skipped rather than failing the
    # whole read. The rotated file is included so a rotation moments ago cannot
    # make a recently-logging lane look silent.
    LOG_LATEST="{}"
    log_files=()
    [ -f "$STATE_DIR/log.jsonl.1" ] && log_files+=("$STATE_DIR/log.jsonl.1")
    [ -f "$STATE_DIR/log.jsonl" ] && log_files+=("$STATE_DIR/log.jsonl")
    if [ "${#log_files[@]}" -gt 0 ]; then
      LOG_LATEST="$(jq -nR '
        [inputs | fromjson? | select((.issue? // null) != null and ((.ts? // "") != ""))]
        | group_by(.issue)
        | map({key: (.[0].issue | tostring), value: (map(.ts) | max)})
        | from_entries' "${log_files[@]}" 2>/dev/null)"
      jq -e . >/dev/null 2>&1 <<<"$LOG_LATEST" || LOG_LATEST="{}"
    fi

    # The latest GitHub starvation window, read bounded from the end of the log
    # (never the whole file) and only from fleet-level lines. A window with no
    # all-clear after it is still open, and runs to now.
    if [ "${#log_files[@]}" -gt 0 ]; then
      starve_window="$(tail -qn 4000 "${log_files[@]}" 2>/dev/null | jq -nRr \
        --arg alarm "$STARVE_ALARM_PREFIX" --arg clear "$STARVE_CLEAR_MESSAGE" '
        [ inputs | fromjson?
          | select((((.issue? // "") | tostring) == "fleet") and ((.ts? // "") != ""))
          | {t: (.ts | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601? // 0),
             m: (.msg // "")}
          | select(.t > 0)
          | if (.m | startswith($alarm)) then {t: .t, k: "alarm"}
            elif .m == $clear then {t: .t, k: "clear"}
            else empty end ]
        | ([.[] | select(.k == "alarm") | .t]) as $alarms
        | ([.[] | select(.k == "clear") | .t]) as $clears
        | if ($alarms | length) == 0 then "0 0 0"
          else ($alarms | max) as $newest
            | ([$clears[] | select(. < $newest)] | max) as $before
            | ([$alarms[] | select($before == null or . > $before)] | min) as $start
            | ([$clears[] | select(. > $newest)] | min) as $end
            | "\($start) \($end // 0) \($newest)"
          end' 2>/dev/null)"
      read -r starve_start_raw starve_end_raw starve_newest_raw <<<"${starve_window:-0 0 0}"
      case "$starve_start_raw" in '' | *[!0-9]*) starve_start_raw=0 ;; esac
      case "$starve_end_raw" in '' | *[!0-9]*) starve_end_raw=0 ;; esac
      case "$starve_newest_raw" in '' | *[!0-9]*) starve_newest_raw=0 ;; esac
      if [ "$starve_start_raw" -gt 0 ]; then
        if [ "$starve_end_raw" -gt 0 ]; then
          # Closed window: GitHub answered again. Its seconds keep being discounted
          # from the quiet clocks for the ceiling's length afterwards -- long enough
          # for a recovering agent to get a full quiet allowance -- and no longer,
          # so a long-past outage never keeps excusing a genuinely stalled agent.
          if [ $((NOW_EPOCH - starve_end_raw)) -lt "$STARVE_CEILING_SECONDS" ]; then
            STARVE_START="$starve_start_raw"
            STARVE_END="$starve_end_raw"
          fi
        elif [ $((NOW_EPOCH - starve_newest_raw)) -lt "$STARVE_CEILING_SECONDS" ]; then
          # Open window: alarms with no all-clear after them, the newest still
          # inside the allowance hour, so the fleet is starved right now.
          STARVE_START="$starve_start_raw"
          STARVE_END="$NOW_EPOCH"
          GITHUB_STARVED=1
        fi
      fi
    fi
    while IFS=$'\t' read -r name pane_id agent_status revision; do
      [ -n "$name" ] || continue
      issue="$(agent_issue_number "$name")"
      [ -n "$issue" ] || continue # not one of the fleet's own agents: ignored

      record_file="$TASKS_DIR/$issue.json"
      [ -f "$record_file" ] || continue
      record="$(cat "$record_file")"

      # A paused lane is a human holding it on purpose: never touched.
      paused="$(jq -r '.paused // false' <<<"$record")"
      [ "$paused" = "true" ] && continue

      # A parked or finished lane has no work left to protect: its agent is
      # expected to be quiet, so nudging it is noise and a third strike would
      # close a pane a human may still want to read. Seen live 2026-08-25:
      # lane 1888 parked itself, then got nudged for looking quiet.
      lane_status="$(jq -r '.status // ""' <<<"$record")"
      case "$lane_status" in blocked | done) continue ;; esac

      # An agent that has already finished -- pane left open, terminal manager
      # reports it done -- has nothing left to nudge and nothing to stop. Seen
      # live 2026-08-25: lane 1890's build agent finished, its pane lingered,
      # and the watchdog nudged the corpse twice. tick.sh no longer counts a
      # done agent as live either; the next dispatch simply proceeds past it.
      [ "$agent_status" = "done" ] && continue

      # Only the lane's current worker deserves protection, and which pane
      # that is follows from the record's stage, not from the terminal
      # manager's done/idle flag -- that flag proved unstable live
      # (2026-08-25: finished agents read "done" one minute and "idle" the
      # next after a nudge woke them, and two finished agents got nudged).
      # Building: the record's agent. QA: the record's reviewer. A red
      # verdict: the record's agent, but only when it is the fix worker for
      # this verdict's cause. The record can retain a predecessor's name for
      # one pass while a red cause changes (issue 2014); accepting any
      # fleet-fix name there would nudge the stale CI fixer during QA-red.
      # Every other stage has no worker, so every fleet pane for it is left
      # alone. Keep this rule in step with the spawn guards in tick.sh.
      expected_worker="$(jq -r '
        (.status // "") as $s | (.agent // "") as $a | (.reviewer // "") as $r
        | if $s == "building" then $a
          elif $s == "qa" then $r
          elif $s == "ci-red" and ($a | test("^fleet-fix-[0-9]+-ci-r[0-9]+$")) then $a
          elif $s == "qa-red" and ($a | test("^fleet-fix-[0-9]+-qa-r[0-9]+$")) then $a
          else "" end' <<<"$record" 2>/dev/null)"
      [ "$name" = "$expected_worker" ] || continue

      last_revision="$(state_get "$name" revision)"
      last_quiet_since="$(state_get "$name" quiet_since)"
      last_nudge_count="$(state_get "$name" nudge_count)"
      last_cpu_ticks="$(state_get "$name" cpu_ticks)"
      last_content_since="$(state_get "$name" content_since)"

      [ -n "$last_quiet_since" ] || last_quiet_since="$NOW_EPOCH"
      case "$last_nudge_count" in '' | *[!0-9]*) last_nudge_count=0 ;; esac
      # State files written before the content clock existed have no
      # content_since; the quiet clock is a safe stand-in, because quiet time
      # only ever accumulated while the content was not changing.
      case "$last_content_since" in '' | *[!0-9]*) last_content_since="$last_quiet_since" ;; esac

      pid="$(pane_top_pid "$pane_id")"
      cpu_ticks=""
      [ -n "$pid" ] && cpu_ticks="$(process_family_cpu_ticks "$pid")"

      # Did the process family measurably compute since the last pass? Only
      # readable counters on both passes can say yes; anything unreadable stays
      # "no", which fails safe (quiet accumulates, and the third strike below
      # nudges instead of stopping when it cannot see the process).
      cpu_moved=0
      case "$cpu_ticks" in
        '' | *[!0-9]*) : ;;
        *) case "$last_cpu_ticks" in
             '' | *[!0-9]*) : ;;
             *) [ "$cpu_ticks" -gt "$last_cpu_ticks" ] && cpu_moved=1 ;;
           esac ;;
      esac

      # The work-based quiet signal: when did this lane last show real work --
      # a record update or a log line? An agent idle at its interactive prompt
      # keeps repainting its status line and burning a CPU trickle (observed
      # live 2026-08-25), so pane revision and CPU ticks alone cannot be
      # trusted as signs of life. If both work trails are WORK_QUIET_SECONDS
      # stale, this agent counts as quiet no matter what the pane does. With
      # neither trail carrying a timestamp at all, 30 minutes of staleness
      # cannot be established, so the signal stays off (fail-safe: no nudge).
      record_updated="$(jq -r '.updated_at // empty' <<<"$record")"
      record_epoch=0
      [ -n "$record_updated" ] && record_epoch="$(iso_to_epoch "$record_updated")"
      record_age=999999999
      [ "$record_epoch" -gt 0 ] && record_age=$((NOW_EPOCH - record_epoch))
      log_ts="$(jq -r --arg i "$issue" '.[$i] // empty' <<<"$LOG_LATEST" 2>/dev/null)"
      log_epoch=0
      [ -n "$log_ts" ] && log_epoch="$(iso_to_epoch "$log_ts")"
      work_last="$record_epoch"
      [ "$log_epoch" -gt "$work_last" ] && work_last="$log_epoch"
      # Time the whole fleet spent waiting on GitHub is not this lane's silence,
      # so it is subtracted before the staleness is judged.
      work_quiet=0
      if [ "$work_last" -gt 0 ]; then
        work_silent=$((NOW_EPOCH - work_last - $(starved_seconds_since "$work_last")))
        [ "$work_silent" -ge "$WORK_QUIET_SECONDS" ] && work_quiet=1
      fi

      # Actual pane-content change is normally the one self-evident sign of
      # life: it resets both the quiet clock and the backstop's content clock.
      # But while the work-based signal says the lane has done nothing for half
      # an hour, a changing revision is just the prompt repainting itself, so
      # only the backstop's content clock resets and the quiet ladder runs on.
      if [ "$revision" != "$last_revision" ]; then
        if [ "$work_quiet" = "1" ]; then
          last_content_since="$NOW_EPOCH"
        else
          state_save "$name" "$NOW_EPOCH" 0 "$revision" "$cpu_ticks" "$pid" "$NOW_EPOCH"
          continue
        fi
      fi

      content_quiet_seconds=$((NOW_EPOCH - last_content_since))

      # The 3-hour backstop: the process check protects the healthy-but-slow agent,
      # but it cannot catch the opposite wedge -- a real infinite loop burning CPU
      # forever while the pane and the lane record never change. Escalate straight
      # to a stop here, regardless of what the process check (or a "working"
      # self-report) would have said; it runs on the content clock, which nothing
      # but a real pane-content change ever resets.
      if [ "$content_quiet_seconds" -ge "$BACKSTOP_SECONDS" ] && [ "$record_age" -ge "$BACKSTOP_SECONDS" ]; then
        stop_agent "$issue" "$name" "$pane_id" \
          "the pane and the lane record have both been unchanged for 3 hours; stopping even though CPU may still be moving, in case this is a genuine infinite loop"
        continue
      fi

      # "Working" is a self-report, and an agent stuck inside one endless tool
      # call reports itself as working the whole time -- the commonest wedge. So
      # a working report only counts as a sign of life when the process check
      # backs it up: CPU moved since the last pass. A working report with flat
      # (or unreadable) CPU lets quiet time accumulate like any silent pane, so
      # the nudges and the strike logic below still connect.
      # A stale work trail overrides this too: an idle prompt's CPU trickle
      # looks like movement, so it must not reset the quiet clock either.
      if [ "$agent_status" = "working" ] && [ "$cpu_moved" = "1" ] && [ "$work_quiet" != "1" ]; then
        state_save "$name" "$NOW_EPOCH" 0 "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      # While GitHub is refusing to answer, every lane can be silent for the same
      # reason -- it is blocked on the world, not wedged -- so the quiet ladder is
      # held here: no nudge, no strike, and the nudge count and quiet clock are
      # carried forward untouched. The 3-hour backstop above has already run and is
      # deliberately not held: it is the last line of defence.
      if [ "$GITHUB_STARVED" = "1" ]; then
        note_github_hold
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      # Once the work trail is half an hour stale, the agent counts as quiet
      # from that point on: pull the quiet clock back (never forward) far
      # enough that the first nudge is due now and the usual 15-minute ladder
      # (nudge 2, then the process-checked stop) runs from here.
      if [ "$work_quiet" = "1" ]; then
        work_anchor=$((NOW_EPOCH - NUDGE_INTERVAL_SECONDS))
        [ "$last_quiet_since" -gt "$work_anchor" ] && last_quiet_since="$work_anchor"
      fi

      # Same discount as the work trail: an outage that has since cleared must not
      # have consumed the agent's quiet allowance while it was blocked.
      quiet_seconds=$((NOW_EPOCH - last_quiet_since - $(starved_seconds_since "$last_quiet_since")))

      threshold=$((NUDGE_INTERVAL_SECONDS * (last_nudge_count + 1)))
      if [ "$quiet_seconds" -lt "$threshold" ]; then
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      if [ "$last_nudge_count" -lt 2 ]; then
        send_nudge "$issue" "$name" "$((last_nudge_count + 1))"
        state_save "$name" "$last_quiet_since" "$((last_nudge_count + 1))" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      # Third strike: never kill on quiet alone. The process check must actually be
      # readable, and there must be a previous pass to compare against.
      process_check_available=1
      [ -n "$pid" ] || process_check_available=0
      case "$cpu_ticks" in '' | *[!0-9]*) process_check_available=0 ;; esac
      case "$last_cpu_ticks" in '' | *[!0-9]*) process_check_available=0 ;; esac

      if [ "$process_check_available" != "1" ]; then
        send_nudge_unavailable "$issue" "$name"
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      if [ "$cpu_moved" = "1" ]; then
        fctl log "$issue" "watchdog: quiet but computing -- $name's process used CPU since the last check ($last_cpu_ticks to $cpu_ticks ticks), so it is not being stopped"
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
        continue
      fi

      # A process that escaped the pane still protects the worktree. Runtime
      # wrappers (including Codex's node/codex session) were filtered above;
      # anything else is orphan work and anything unverifiable stays protected.
      worktree="$(jq -r '.worktree // empty' <<<"$record" 2>/dev/null)"
      if [ -n "$worktree" ] && [ -d "$worktree" ]; then
        orphan_state=0
        worktree_orphan_state "$worktree" "$pid" || orphan_state=$?
        case "$orphan_state" in
          0)
            fctl log "$issue" "watchdog: quiet but computing -- an orphaned worktree process protects $name, so it is not being stopped"
            state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
            continue
            ;;
          2)
            send_nudge_unavailable "$issue" "$name"
            state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid" "$last_content_since"
            continue
            ;;
        esac
      fi

      stop_agent "$issue" "$name" "$pane_id" \
        "quiet for the third check in a row and the process is confirmed flat (CPU stayed at $cpu_ticks ticks between the last two checks)"
    done < <(jq -r --argjson tabs "$TAB_IDS" \
      '.result.agents[]? | select(((.tab_id // "") as $t | ($tabs | index($t)) != null) and (.name // "") != "") | [.name, .pane_id, (.agent_status // "unknown"), ((.revision // 0) | tostring)] | @tsv' \
      <<<"$AGENTS_JSON" 2>/dev/null)
  fi
fi

# Carried forward only when the hold actually spoke this pass, so the next pass
# knows this outage has already been logged and stays silent about it.
if [ "$GITHUB_HOLD_NOTED" = "1" ]; then
  NEW_STATE="$(jq --arg k "$STARVE_NOTE_KEY" --argjson s "$STARVE_START" '.[$k] = {noted_for: $s}' <<<"$NEW_STATE")"
fi

# Written atomically (temp file, then rename over), like every other state
# write in this repo, so a pass killed mid-write can never leave a truncated
# state file for the next pass to mistake for "no history".
WATCHDOG_STATE_TMP="$WATCHDOG_STATE_FILE.tmp-$$"
printf '%s' "$NEW_STATE" > "$WATCHDOG_STATE_TMP" && mv -f "$WATCHDOG_STATE_TMP" "$WATCHDOG_STATE_FILE"
exit 0
