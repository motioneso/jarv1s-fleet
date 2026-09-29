#!/usr/bin/env bash
set -euo pipefail

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/bin" "$task_tmp/state/jarv1s-coordinator-watchdog"

cat >"$task_tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "pane list" ]; then
  printf '%s\n' "$WATCHDOG_TEST_PANE_JSON"
  exit 0
fi
exit 2
EOF
chmod +x "$task_tmp/bin/herdr"

state_file="$task_tmp/state/jarv1s-coordinator-watchdog/state.json"
printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"

working_json='{"result":{"panes":[{"label":"Coordinator","pane_id":"w1:p1","revision":7,"agent_status":"working"}]}}'
output="$(PATH="$task_tmp/bin:$PATH" XDG_STATE_HOME="$task_tmp/state" WATCHDOG_TEST_PANE_JSON="$working_json" COORDINATOR_WATCHDOG_IDLE_SECONDS=1 COORDINATOR_WATCHDOG_DRY_RUN=1 scripts/coordinator-watchdog.sh)"
[ -z "$output" ]
[ "$(jq -r '.last_change' "$state_file")" -gt 1 ]

printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"
idle_json='{"result":{"panes":[{"label":"Coordinator","pane_id":"w1:p1","revision":7,"agent_status":"idle"}]}}'
output="$(PATH="$task_tmp/bin:$PATH" XDG_STATE_HOME="$task_tmp/state" WATCHDOG_TEST_PANE_JSON="$idle_json" COORDINATOR_WATCHDOG_IDLE_SECONDS=1 COORDINATOR_WATCHDOG_DRY_RUN=1 scripts/coordinator-watchdog.sh)"
grep -q 'idle for .*s, nudging' <<<"$output"

# A lane check running inside a lane worktree suppresses the nudge.
lane_dir="$task_tmp/repo/.claude/worktrees/lane-a"
mkdir -p "$lane_dir"
lane_json="{\"result\":{\"panes\":[{\"label\":\"Coordinator\",\"pane_id\":\"w1:p1\",\"workspace_id\":\"w1\",\"cwd\":\"$task_tmp\",\"revision\":7,\"agent_status\":\"idle\"},{\"label\":\"lane a\",\"pane_id\":\"w1:p2\",\"workspace_id\":\"w1\",\"cwd\":\"$lane_dir\",\"revision\":3,\"agent_status\":\"idle\"}]}}"
cat >"$task_tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${WATCHDOG_TEST_CI_PENDING:-}" ]; then echo "$WATCHDOG_TEST_CI_PENDING"; exit 0; fi
exit 1
GH
chmod +x "$task_tmp/bin/gh"
run_watchdog() {
  PATH="$task_tmp/bin:$PATH" XDG_STATE_HOME="$task_tmp/state" WATCHDOG_TEST_PANE_JSON="$lane_json" \
    COORDINATOR_WATCHDOG_IDLE_SECONDS=1 COORDINATOR_WATCHDOG_DRY_RUN=1 scripts/coordinator-watchdog.sh
}

(cd "$lane_dir" && exec -a vitest sleep 30) &
check_pid=$!
sleep 0.3
printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"
output="$(run_watchdog)"
kill "$check_pid"
wait "$check_pid" 2>/dev/null || true
[ "$output" = "coordinator-watchdog: lane checks still running, skipping nudge" ]
[ "$(jq -r '.last_change' "$state_file")" -gt 1 ]

# With no check running, the same idle coordinator is nudged.
printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"
output="$(run_watchdog)"
grep -q 'idle for .*s, nudging' <<<"$output"

# A queued or running GitHub check on a lane PR also suppresses the nudge.
git -C "$lane_dir" init -q -b lane-a
printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"
output="$(WATCHDOG_TEST_CI_PENDING=1 run_watchdog)"
[ "$output" = "coordinator-watchdog: lane checks still running, skipping nudge" ]

printf '%s\n' '{"revision":"7","last_change":1,"last_nudge":0}' >"$state_file"
output="$(WATCHDOG_TEST_CI_PENDING=0 run_watchdog)"
grep -q 'idle for .*s, nudging' <<<"$output"

echo "coordinator watchdog tests passed"
