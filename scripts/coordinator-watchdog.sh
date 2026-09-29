#!/usr/bin/env bash
# Nudges the dev-coordinator pane if it goes idle for too long while Ben is away.
# Runs as a systemd oneshot on a 1-minute timer (see systemd/).
set -euo pipefail

IDLE_THRESHOLD_SECONDS="${COORDINATOR_WATCHDOG_IDLE_SECONDS:-300}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jarv1s-coordinator-watchdog"
STATE_FILE="$STATE_DIR/state.json"
mkdir -p "$STATE_DIR"

pane_list="$(herdr pane list)"

# There must be exactly one Coordinator pane (Phase 0a lock). If none exists, there's
# nothing to watch right now -- clear any stale state and exit quietly.
coordinator_rows="$(jq -c '[.result.panes[] | select(.label == "Coordinator")]' <<<"$pane_list")"
if [ "$(jq 'length' <<<"$coordinator_rows")" -ne 1 ]; then
  rm -f "$STATE_FILE"
  exit 0
fi
coordinator="$(jq -c '.[0]' <<<"$coordinator_rows")"

pane_id="$(jq -r '.pane_id' <<<"$coordinator")"
revision="$(jq -r '.revision' <<<"$coordinator")"
agent_status="$(jq -r '.agent_status // "unknown"' <<<"$coordinator")"
now="$(date +%s)"

last_revision=""
last_change="$now"
last_nudge=0
if [ -f "$STATE_FILE" ]; then
  last_revision="$(jq -r '.revision // ""' "$STATE_FILE" 2>/dev/null || echo "")"
  last_change="$(jq -r '.last_change // 0' "$STATE_FILE" 2>/dev/null || echo "$now")"
  last_nudge="$(jq -r '.last_nudge // 0' "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if [ "$agent_status" = "working" ] || [ "$revision" != "$last_revision" ]; then
  # Active work may not emit terminal output, so either signal resets the clock.
  last_change="$now"
fi

idle_seconds=$(( now - last_change ))

# Lanes are the other panes in the coordinator's workspace that sit in a worktree.
coordinator_workspace="$(jq -r '.workspace_id' <<<"$coordinator")"
coordinator_cwd="$(jq -r '.cwd // ""' <<<"$coordinator")"
mapfile -t lane_dirs < <(jq -r --arg ws "$coordinator_workspace" --arg own "$coordinator_cwd" \
  '.result.panes[] | select(.workspace_id == $ws and .label != "Coordinator")
   | .cwd // empty | select(. != $own and contains("/.claude/worktrees/"))' <<<"$pane_list" | sort -u)

CHECK_PATTERN='run-gate\.sh|pnpm (verify|test|lint|typecheck)|vitest|playwright|gh (pr checks|run watch)'

# True when a gate, test run or CI wait is running inside any lane worktree.
local_check_running() {
  local proc cwd dir cmd
  for proc in /proc/[0-9]*; do
    cwd="$(readlink "$proc/cwd" 2>/dev/null)" || continue
    for dir in "${lane_dirs[@]}"; do
      case "$cwd/" in
        "$dir"/*)
          cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null)" || continue
          grep -qE "$CHECK_PATTERN" <<<"$cmd" && return 0
          ;;
      esac
    done
  done
  return 1
}

# True when a lane branch has an open PR with a GitHub check still queued or running.
ci_check_pending() {
  local dir branch pending
  for dir in "${lane_dirs[@]}"; do
    branch="$(git -C "$dir" branch --show-current 2>/dev/null)" || continue
    [ -n "$branch" ] || continue
    pending="$(cd "$dir" && gh pr view "$branch" --json state,statusCheckRollup -q \
      'select(.state == "OPEN") | [.statusCheckRollup[]
       | select((.status // "COMPLETED") != "COMPLETED" or (.state // "") == "PENDING" or (.state // "") == "EXPECTED")]
       | length' 2>/dev/null)" || continue
    [ "${pending:-0}" -gt 0 ] && return 0
  done
  return 1
}

# A lane waiting on checks reports back by itself when they finish, so a nudge now is noise.
# Only look when a nudge is due, to keep GitHub calls to one sweep per idle window.
if [ "$idle_seconds" -ge "$IDLE_THRESHOLD_SECONDS" ] && [ "${#lane_dirs[@]}" -gt 0 ] \
  && { local_check_running || ci_check_pending; }; then
  echo "coordinator-watchdog: lane checks still running, skipping nudge"
  last_change="$now"
elif [ "$idle_seconds" -ge "$IDLE_THRESHOLD_SECONDS" ]; then
  echo "coordinator-watchdog: pane $pane_id idle for ${idle_seconds}s, nudging"
  # Carry the fleet's pane statuses IN the nudge so the coordinator doesn't burn context
  # re-polling `herdr pane list` on every wake (2026-08-23 audit: 242 nudges in two days, each
  # answered with 5-27 identical pane-list calls).
  pane_summary="$(jq -r '[.result.panes[] | "\(.label // .pane_id):\(.agent_status // "?")"] | join(", ")' <<<"$pane_list" 2>/dev/null || echo "unavailable")"
  nudge="Watchdog: no activity for ${IDLE_THRESHOLD_SECONDS}s. Current pane statuses (fresh, do NOT re-poll pane list): ${pane_summary}. Act only on lanes that need it per the run manifest -- if a lane needs a decision only Ben can make, log it and ping him rather than sitting idle."
  if [ "${COORDINATOR_WATCHDOG_DRY_RUN:-0}" = "1" ]; then
    echo "coordinator-watchdog: DRY RUN, would send to $pane_id: $nudge"
  else
    # Prefer the agent API: it routes by the durable agent name and submits atomically.
    # Fall back to the pane API only when Herdr has not registered the occupant as an agent.
    agent_name="$(herdr agent list | jq -r --arg pane "$pane_id" \
      '.result.agents[] | select(.pane_id == $pane) | .name // empty' | head -n1)"
    if [ -n "$agent_name" ]; then
      herdr agent prompt "$agent_name" "$nudge" >/dev/null
    else
      herdr pane run "$pane_id" "$nudge" >/dev/null
    fi
  fi
  last_nudge="$now"
  # Give it a fresh window before nudging again, so a still-stuck coordinator gets
  # re-nudged every IDLE_THRESHOLD_SECONDS instead of every single poll.
  last_change="$now"
fi

jq -n --arg revision "$revision" --argjson last_change "$last_change" --argjson last_nudge "$last_nudge" \
  '{revision: $revision, last_change: $last_change, last_nudge: $last_nudge}' > "$STATE_FILE"
