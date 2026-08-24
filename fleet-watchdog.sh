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
  if [[ "$name" =~ ^fleet-(lane|qa|fix|rescue)-([0-9]+)(-r[0-9]+)?(-retry)?$ ]]; then
    echo "${BASH_REMATCH[2]}"
  fi
}

agent_tab_id() { # -> the tab lane agents share, or empty if it does not exist yet
  herdr tab list 2>/dev/null |
    jq -r --arg label "$AGENT_TAB_LABEL" \
      '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -n1
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
  local ppid="$1" f rest fields
  for f in "$PROC_DIR"/[0-9]*/stat; do
    [ -f "$f" ] || continue
    rest="$(cat "$f" 2>/dev/null)" || continue
    rest="${rest##*) }"
    read -r -a fields <<<"$rest"
    if [ "${fields[1]:-}" = "$ppid" ]; then
      basename "$(dirname "$f")"
    fi
  done
}

# Total CPU ticks (utime+stime) used by a process and every descendant it has spawned,
# summed across the whole family. Empty means the table could not be read or the
# process was not found -- the caller must treat that as "unavailable", never as zero.
# Why total ticks compared between one-minute passes, not a single snapshot: a single
# instant only catches a process if it happens to be on the CPU at that exact moment,
# so a busy-but-bursty process can read as idle. The ticks counter only ever goes up,
# so a between-passes comparison cannot be fooled that way.
process_family_cpu_ticks() { # <root pid> -> total ticks, or empty
  local root="$1" stat_file rest fields utime stime total=0 found=0
  local -a queue=("$root")
  [ -d "$PROC_DIR" ] || return 0
  while [ "${#queue[@]}" -gt 0 ]; do
    local pid="${queue[0]}"
    queue=("${queue[@]:1}")
    stat_file="$PROC_DIR/$pid/stat"
    [ -f "$stat_file" ] || continue
    rest="$(cat "$stat_file" 2>/dev/null)" || continue
    # Fields after the comm field's closing paren are space-separated and fixed in
    # order; comm itself may contain spaces or parens, so split on the LAST ")".
    rest="${rest##*) }"
    read -r -a fields <<<"$rest"
    # 0-indexed from "state": state(0) ppid(1) pgrp(2) session(3) tty_nr(4) tpgid(5)
    # flags(6) minflt(7) cminflt(8) majflt(9) cmajflt(10) utime(11) stime(12) ...
    utime="${fields[11]:-}"
    stime="${fields[12]:-}"
    case "$utime$stime" in '' | *[!0-9]*) continue ;; esac
    total=$((total + utime + stime))
    found=1
    while IFS= read -r child; do
      [ -n "$child" ] && queue+=("$child")
    done < <(children_of "$pid")
  done
  [ "$found" = "1" ] || return 0
  echo "$total"
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

state_get() { # <agent name> <field> -> value, or empty
  jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // empty' <<<"$WATCHDOG_STATE" 2>/dev/null
}

# Carries one agent's row forward into the state file being built for this pass.
state_save() { # <agent name> <quiet_since> <nudge_count> <revision> <cpu_ticks> <cpu_pid>
  NEW_STATE="$(jq \
    --arg n "$1" --argjson quiet_since "$2" --argjson nudge_count "$3" \
    --arg revision "$4" --arg cpu_ticks "$5" --arg cpu_pid "$6" \
    '.[$n] = {quiet_since: $quiet_since, nudge_count: $nudge_count, revision: $revision, cpu_ticks: $cpu_ticks, cpu_pid: $cpu_pid}' \
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

stop_agent() { # <issue> <agent name> <pane id> <plain-English reason, with CPU numbers where relevant>
  local issue="$1" name="$2" pane="$3" reason="$4"
  act herdr pane close "$pane" >/dev/null
  fctl log "$issue" "watchdog: stopped $name -- $reason"
}

# --- one pass over every fleet agent in the shared tab -----------------------------

TAB_ID="$(agent_tab_id)"
if [ -n "$TAB_ID" ]; then
  AGENTS_JSON="$(herdr agent list 2>/dev/null)"
  if [ -n "$AGENTS_JSON" ]; then
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

      last_revision="$(state_get "$name" revision)"
      last_quiet_since="$(state_get "$name" quiet_since)"
      last_nudge_count="$(state_get "$name" nudge_count)"
      last_cpu_ticks="$(state_get "$name" cpu_ticks)"

      [ -n "$last_quiet_since" ] || last_quiet_since="$NOW_EPOCH"
      case "$last_nudge_count" in '' | *[!0-9]*) last_nudge_count=0 ;; esac

      # Signs of life: the pane reporting "working", or any change in its content
      # (revision). "Working" alone is not trusted past this -- an agent stuck in
      # one endless tool call reports itself as working the whole time, so the
      # process check below is what actually decides a kill.
      sign_of_life=0
      if [ "$agent_status" = "working" ] || [ "$revision" != "$last_revision" ]; then
        sign_of_life=1
      fi

      pid="$(pane_top_pid "$pane_id")"
      cpu_ticks=""
      [ -n "$pid" ] && cpu_ticks="$(process_family_cpu_ticks "$pid")"

      if [ "$sign_of_life" = "1" ]; then
        state_save "$name" "$NOW_EPOCH" 0 "$revision" "$cpu_ticks" "$pid"
        continue
      fi

      quiet_seconds=$((NOW_EPOCH - last_quiet_since))
      record_updated="$(jq -r '.updated_at // empty' <<<"$record")"
      record_age=999999999
      [ -n "$record_updated" ] && record_age=$((NOW_EPOCH - $(iso_to_epoch "$record_updated")))

      # The 3-hour backstop: the process check protects the healthy-but-slow agent,
      # but it cannot catch the opposite wedge -- a real infinite loop burning CPU
      # forever while the pane and the lane record never change. Escalate straight
      # to a stop here, regardless of what the process check would have said.
      if [ "$quiet_seconds" -ge "$BACKSTOP_SECONDS" ] && [ "$record_age" -ge "$BACKSTOP_SECONDS" ]; then
        stop_agent "$issue" "$name" "$pane_id" \
          "the pane and the lane record have both been unchanged for 3 hours; stopping even though CPU may still be moving, in case this is a genuine infinite loop"
        continue
      fi

      threshold=$((NUDGE_INTERVAL_SECONDS * (last_nudge_count + 1)))
      if [ "$quiet_seconds" -lt "$threshold" ]; then
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid"
        continue
      fi

      if [ "$last_nudge_count" -lt 2 ]; then
        send_nudge "$issue" "$name" "$((last_nudge_count + 1))"
        state_save "$name" "$last_quiet_since" "$((last_nudge_count + 1))" "$revision" "$cpu_ticks" "$pid"
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
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid"
        continue
      fi

      if [ "$cpu_ticks" -gt "$last_cpu_ticks" ]; then
        fctl log "$issue" "watchdog: quiet but computing -- $name's process used CPU since the last check ($last_cpu_ticks to $cpu_ticks ticks), so it is not being stopped"
        state_save "$name" "$last_quiet_since" "$last_nudge_count" "$revision" "$cpu_ticks" "$pid"
        continue
      fi

      stop_agent "$issue" "$name" "$pane_id" \
        "quiet for the third check in a row and the process is confirmed flat (CPU stayed at $cpu_ticks ticks between the last two checks)"
    done < <(jq -r --arg tab "$TAB_ID" \
      '.result.agents[]? | select(.tab_id == $tab and (.name // "") != "") | [.name, .pane_id, (.agent_status // "unknown"), ((.revision // 0) | tostring)] | @tsv' \
      <<<"$AGENTS_JSON" 2>/dev/null)
  fi
fi

printf '%s' "$NEW_STATE" > "$WATCHDOG_STATE_FILE"
exit 0
