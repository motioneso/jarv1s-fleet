#!/usr/bin/env bash
# Tests for fleet-watchdog.sh. Everything external is stubbed with PATH shims
# (herdr, fleetctl), and the system process table is a fixture directory, so no real
# agent is ever wedged, nudged, or stopped by these tests.
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watchdog="$tool_root/fleet-watchdog.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/logs"

export SHIM_LOG_DIR="$tmp/logs"

cat >"$tmp/bin/fleetctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/fleetctl.log"
EOF

cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/herdr.log"
no_tabs='{"result":{"tabs":[]}}'
no_agents='{"result":{"agents":[]}}'
no_process_info='{"result":{}}'
case "$1 $2" in
  "tab list")           printf '%s\n' "${HERDR_TABS_JSON:-$no_tabs}" ;;
  "agent list")         printf '%s\n' "${HERDR_AGENTS_JSON:-$no_agents}" ;;
  "pane process-info")  printf '%s\n' "${HERDR_PROCESS_INFO_JSON:-$no_process_info}" ;;
  "agent prompt")       echo "PROMPT $3 :: $4" >> "$SHIM_LOG_DIR/herdr-prompts.log" ;;
  "pane close")         echo "CLOSE $3" >> "$SHIM_LOG_DIR/herdr-closes.log" ;;
esac
EOF

chmod +x "$tmp/bin/"*

# --- helpers --------------------------------------------------------------------

pass() { echo "PASS: $1"; }

new_state() { # -> fresh state dir with a tasks folder, echoes its path
  local d
  d="$(mktemp -d "$tmp/state-XXXX")"
  mkdir -p "$d/tasks"
  echo "$d"
}

write_record() { # <state-dir> <issue> <json>
  printf '%s\n' "$3" > "$1/tasks/$2.json"
}

write_watchdog_state() { # <state-dir> <json>
  printf '%s' "$2" > "$1/.watchdog-state.json"
}

clear_logs() {
  rm -f "$SHIM_LOG_DIR"/*.log
}

# A fixture /proc/<pid>/stat entry: real /proc/pid/stat layout after "pid (comm) ",
# so process_family_cpu_ticks() reads the same utime/stime field positions it would
# on a real box. Extra trailing zeros pad out fields the watchdog never reads.
write_proc_stat() { # <proc-dir> <pid> <ppid> <utime> <stime>
  mkdir -p "$1/$2"
  printf '%s (proc%s) S %s 0 0 0 0 0 0 0 0 0 %s %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' \
    "$2" "$2" "$3" "$4" "$5" > "$1/$2/stat"
}

# One tab, "Fleet Agents", id w1:tA -- every test's agents live in it.
tabs_json='{"result":{"tabs":[{"label":"Fleet Agents","tab_id":"w1:tA"}]}}'

# <name> <pane_id> <agent_status> <revision> -> one herdr agent-list entry, tab_id
# always w1:tA. Several can be joined with commas into HERDR_AGENTS_JSON.
agent_entry() {
  printf '{"name":"%s","pane_id":"%s","tab_id":"w1:tA","agent_status":"%s","revision":%s}' \
    "$1" "$2" "$3" "$4"
}

run_watchdog() { # <state-dir> [extra env KEY=VAL...]
  local state="$1"
  shift
  PATH="$tmp/bin:$PATH" \
    JARV1S_FLEET_STATE="$state" \
    HERDR_TABS_JSON="$tabs_json" \
    env "$@" "$watchdog"
}

now="$(date +%s)"
now_iso="$(date -Iseconds)"

# --- 1. a pane with no fleet agent is ignored --------------------------------------

state="$(new_state)"
clear_logs
run_watchdog "$state" HERDR_AGENTS_JSON="{\"result\":{\"agents\":[{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:tA\",\"agent_status\":\"idle\",\"revision\":1}]}}"
[ ! -s "$SHIM_LOG_DIR/fleetctl.log" ]
[ ! -f "$SHIM_LOG_DIR/herdr-prompts.log" ]
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
pass "a pane with no fleet agent name is ignored"

# --- 2. a paused lane is never touched, even if long overdue for a stop -----------

state="$(new_state)"
write_record "$state" 401 "{\"issue\":401,\"status\":\"building\",\"paused\":true,\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-401\":{\"quiet_since\":$((now - 20000)),\"nudge_count\":2,\"revision\":\"1\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"1\"}}"
clear_logs
run_watchdog "$state" HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-401 w1:p1 idle 1)]}}"
[ ! -s "$SHIM_LOG_DIR/fleetctl.log" ]
[ ! -f "$SHIM_LOG_DIR/herdr-prompts.log" ]
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
pass "a paused lane is never touched"

# --- 3. a quiet lane gets a nudge (first quiet period) -----------------------------

state="$(new_state)"
write_record "$state" 402 "{\"issue\":402,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-402\":{\"quiet_since\":$((now - 901)),\"nudge_count\":0,\"revision\":\"9\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"555\"}}"
clear_logs
run_watchdog "$state" HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-402 w1:p1 idle 9)]}}"
grep -q "PROMPT fleet-lane-402" "$SHIM_LOG_DIR/herdr-prompts.log"
grep -q "log 402 watchdog: sent nudge 1 of 2" "$SHIM_LOG_DIR/fleetctl.log"
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q '"nudge_count": 1' "$state/.watchdog-state.json"
pass "a quiet lane gets a nudge, not a stop, on its first quiet period"

# --- 4. a second quiet period gets a second nudge, still not a stop ---------------

state="$(new_state)"
write_record "$state" 403 "{\"issue\":403,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-403\":{\"quiet_since\":$((now - 1801)),\"nudge_count\":1,\"revision\":\"2\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"1\"}}"
clear_logs
run_watchdog "$state" HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-403 w1:p1 idle 2)]}}"
grep -q "log 403 watchdog: sent nudge 2 of 2" "$SHIM_LOG_DIR/fleetctl.log"
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q '"nudge_count": 2' "$state/.watchdog-state.json"
pass "a second quiet period gets nudge 2 of 2, still not a stop"

# --- 5. signs of life (working, or a revision change) reset the clock -------------

state="$(new_state)"
write_record "$state" 404 "{\"issue\":404,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-404\":{\"quiet_since\":$((now - 5000)),\"nudge_count\":1,\"revision\":\"3\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"1\"}}"
clear_logs
run_watchdog "$state" HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-404 w1:p1 working 3)]}}"
[ ! -s "$SHIM_LOG_DIR/fleetctl.log" ]
[ ! -f "$SHIM_LOG_DIR/herdr-prompts.log" ]
grep -q '"nudge_count": 0' "$state/.watchdog-state.json"
pass "a pane reporting working resets the quiet clock and nudge count"

# --- 6. third strike proceeds when the process check confirms flat CPU -----------

state="$(new_state)"
proc="$tmp/proc-flat"
write_proc_stat "$proc" 777 1 60 40 # 100 ticks total, same as last pass
write_record "$state" 405 "{\"issue\":405,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-405\":{\"quiet_since\":$((now - 2701)),\"nudge_count\":2,\"revision\":\"4\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"777\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-405 w1:p1 idle 4)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{"foreground_process_group_id":777}}}' \
  FLEET_PROC_DIR="$proc"
grep -q "CLOSE w1:p1" "$SHIM_LOG_DIR/herdr-closes.log"
grep -q "log 405 watchdog: stopped fleet-lane-405 -- quiet for the third check in a row and the process is confirmed flat (CPU stayed at 100 ticks" "$SHIM_LOG_DIR/fleetctl.log"
[ ! -f "$SHIM_LOG_DIR/herdr-prompts.log" ]
pass "third strike with CPU confirmed flat stops the agent, not another nudge"

# --- 7. CPU that grew between passes is never killed, logged quiet-but-computing -

state="$(new_state)"
proc="$tmp/proc-growing"
write_proc_stat "$proc" 778 1 90 60 # 150 ticks total, up from 100 last pass
write_record "$state" 406 "{\"issue\":406,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-406\":{\"quiet_since\":$((now - 2701)),\"nudge_count\":2,\"revision\":\"5\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"778\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-406 w1:p1 idle 5)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{"foreground_process_group_id":778}}}' \
  FLEET_PROC_DIR="$proc"
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q "log 406 watchdog: quiet but computing -- fleet-lane-406's process used CPU since the last check (100 to 150 ticks)" "$SHIM_LOG_DIR/fleetctl.log"
grep -q '"cpu_ticks": "150"' "$state/.watchdog-state.json"
pass "CPU that grew between passes is never killed, logged as quiet but computing"

# --- 8. an unreadable process table never kills; nudges and logs unavailable -----

state="$(new_state)"
write_record "$state" 407 "{\"issue\":407,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-407\":{\"quiet_since\":$((now - 2701)),\"nudge_count\":2,\"revision\":\"6\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"779\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-407 w1:p1 idle 6)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{"foreground_process_group_id":779}}}' \
  FLEET_PROC_DIR="$tmp/no-such-proc-dir"
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q "PROMPT fleet-lane-407" "$SHIM_LOG_DIR/herdr-prompts.log"
grep -q "log 407 watchdog: process check unavailable" "$SHIM_LOG_DIR/fleetctl.log"
pass "an unreadable process table never kills; nudges and logs the check as unavailable"

# --- 9. no previous CPU counter to compare against never kills either -------------

state="$(new_state)"
proc="$tmp/proc-nohistory"
write_proc_stat "$proc" 780 1 10 10
write_record "$state" 408 "{\"issue\":408,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-408\":{\"quiet_since\":$((now - 2701)),\"nudge_count\":2,\"revision\":\"7\",\"cpu_ticks\":\"\",\"cpu_pid\":\"\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-408 w1:p1 idle 7)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{"foreground_process_group_id":780}}}' \
  FLEET_PROC_DIR="$proc"
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q "log 408 watchdog: process check unavailable" "$SHIM_LOG_DIR/fleetctl.log"
pass "a missing previous CPU reading never kills either; nudges instead"

# --- 10. the pane's top process cannot be found: same fail-safe -------------------

state="$(new_state)"
write_record "$state" 409 "{\"issue\":409,\"status\":\"building\",\"updated_at\":\"$now_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-409\":{\"quiet_since\":$((now - 2701)),\"nudge_count\":2,\"revision\":\"8\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"781\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-409 w1:p1 idle 8)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{}}}'
[ ! -f "$SHIM_LOG_DIR/herdr-closes.log" ]
grep -q "log 409 watchdog: process check unavailable" "$SHIM_LOG_DIR/fleetctl.log"
pass "a pane whose top process cannot be found never kills; fails safe with a nudge"

# --- 11. the 3-hour backstop escalates even while CPU is still growing ------------

state="$(new_state)"
proc="$tmp/proc-backstop"
write_proc_stat "$proc" 782 1 150 150 # 300 ticks, well above the 100 recorded last pass
old_iso="$(date -Iseconds -d "@$((now - 10900))")"
write_record "$state" 410 "{\"issue\":410,\"status\":\"building\",\"updated_at\":\"$old_iso\"}"
write_watchdog_state "$state" "{\"fleet-lane-410\":{\"quiet_since\":$((now - 10900)),\"nudge_count\":2,\"revision\":\"9\",\"cpu_ticks\":\"100\",\"cpu_pid\":\"782\"}}"
clear_logs
run_watchdog "$state" \
  HERDR_AGENTS_JSON="{\"result\":{\"agents\":[$(agent_entry fleet-lane-410 w1:p1 idle 9)]}}" \
  HERDR_PROCESS_INFO_JSON='{"result":{"process_info":{"foreground_process_group_id":782}}}' \
  FLEET_PROC_DIR="$proc"
grep -q "CLOSE w1:p1" "$SHIM_LOG_DIR/herdr-closes.log"
grep -q "log 410 watchdog: stopped fleet-lane-410 -- the pane and the lane record have both been unchanged for 3 hours" "$SHIM_LOG_DIR/fleetctl.log"
pass "the 3-hour backstop escalates to a stop even though CPU is still moving"

echo "All fleet-watchdog tests passed."
