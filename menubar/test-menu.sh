#!/usr/bin/env bash
# Builds a throwaway fleet state directory under /tmp, runs fleet-menu.mjs
# against it, and checks the printed menu follows the rules in
# docs/plans/menubar-swiftbar.md. Exits non-zero on any miss.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fleet-menu.mjs"

FIXTURE_DIR="$(mktemp -d /tmp/fleet-menu-test.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/tasks"

now_iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# Lane 1: working, has a PR, updated 12 minutes ago.
cat > "$FIXTURE_DIR/tasks/1945.json" <<JSON
{
  "issue": 1945,
  "title": "Workshop part 1: real build data",
  "status": "building",
  "pr": 1950,
  "blocked_reason": null,
  "resliced_to": null,
  "spec": "https://github.com/motioneso/moss/issues/1945",
  "updated_at": "$(now_iso '12 minutes ago')",
  "paused": false
}
JSON

# Lane 2: blocked, genuinely waiting on a human.
cat > "$FIXTURE_DIR/tasks/1902.json" <<JSON
{
  "issue": 1902,
  "title": "Needs a database decision",
  "status": "blocked",
  "pr": null,
  "blocked_reason": "needs a database decision",
  "question": "needs a database decision",
  "resliced_to": null,
  "spec": "https://github.com/motioneso/moss/issues/1902",
  "updated_at": "$(now_iso '5 minutes ago')",
  "paused": false
}
JSON

# Lane 3: re-sliced - must show gray, "split into a follow-up", and must
# NOT count as waiting on a human.
cat > "$FIXTURE_DIR/tasks/1889.json" <<JSON
{
  "issue": 1889,
  "title": "Old work, now split",
  "status": "blocked",
  "pr": null,
  "blocked_reason": "re-sliced automatically: remaining work is issue #1945",
  "resliced_to": 1945,
  "spec": "https://github.com/motioneso/moss/issues/1889",
  "updated_at": "$(now_iso '20 minutes ago')",
  "paused": false
}
JSON

# Lane 4: done recently - must appear.
cat > "$FIXTURE_DIR/tasks/1943.json" <<JSON
{
  "issue": 1943,
  "title": "Workshop: asking Moss for a module",
  "status": "done",
  "pr": null,
  "blocked_reason": null,
  "resliced_to": null,
  "spec": "https://github.com/motioneso/moss/issues/1943",
  "updated_at": "$(now_iso '1 hour ago')",
  "paused": false
}
JSON

# Lane 5: done a full day ago - must be omitted.
cat > "$FIXTURE_DIR/tasks/1800.json" <<JSON
{
  "issue": 1800,
  "title": "Ancient finished work",
  "status": "done",
  "pr": null,
  "blocked_reason": null,
  "resliced_to": null,
  "spec": "https://github.com/motioneso/moss/issues/1800",
  "updated_at": "$(now_iso '30 hours ago')",
  "paused": false
}
JSON

# 7 queued lanes - backlog, not active work. Must not count toward the
# title's working number, must not each get their own row, and must be
# collapsed into one "more queued" summary row instead.
QUEUED_COUNT=7
for i in $(seq 1 "$QUEUED_COUNT"); do
  issue=$((2000 + i))
  cat > "$FIXTURE_DIR/tasks/${issue}.json" <<JSON
{
  "issue": $issue,
  "title": "Backlog item $i",
  "status": "queued",
  "pr": null,
  "blocked_reason": null,
  "resliced_to": null,
  "spec": "https://github.com/motioneso/moss/issues/$issue",
  "updated_at": "$(now_iso "$((i + 30)) minutes ago")",
  "paused": false
}
JSON
done

# Log: one ALARM in the last hour (must appear), one ALARM from well over
# an hour ago (must be absent).
cat > "$FIXTURE_DIR/log.jsonl" <<JSONL
{"ts":"$(now_iso '10 minutes ago')","issue":"fleet","msg":"ALARM: fleet code has uncommitted edits"}
{"ts":"$(now_iso '5 hours ago')","issue":"fleet","msg":"ALARM: stale problem from earlier tonight"}
JSONL

# A run-started marker and a spawn count, plain integer form.
touch "$FIXTURE_DIR/run-started"
echo "6" > "$FIXTURE_DIR/.spawn-count"

OUTPUT="$(JARV1S_FLEET_STATE="$FIXTURE_DIR" node "$SCRIPT")"

fail() {
  echo "FAIL: $1" >&2
  echo "--- full output ---" >&2
  echo "$OUTPUT" >&2
  exit 1
}

# Title: only 1945 (status "building") is active work, so working count = 1.
# Waiting count = 1 (1902). Re-sliced lane 1889 is blocked but must not add
# to the waiting count. The 7 queued lanes must not count as working either.
echo "$OUTPUT" | head -1 | grep -qx "Fleet 1 !1" || fail "title line wrong, got: $(echo "$OUTPUT" | head -1)"

# Queued lanes: none shown individually, one summary row with the right count.
echo "$OUTPUT" | grep -q "Backlog item" && fail "individual queued lane rows should not appear"
echo "$OUTPUT" | grep -qx "$QUEUED_COUNT more queued | color=gray" || fail "queued summary row missing or wrong, expected '$QUEUED_COUNT more queued'"

# WAITING ON YOU section present with the waiting lane's reason.
echo "$OUTPUT" | grep -q "^WAITING ON YOU" || fail "missing WAITING ON YOU section"
echo "$OUTPUT" | grep -q "#1902 needs a database decision" || fail "waiting lane row missing or wrong text"

# Re-sliced lane shown gray, described as split, not in the waiting section.
echo "$OUTPUT" | grep -q "#1889 split into a follow-up (issue #1945) | color=gray" || fail "split lane row missing or wrong"
echo "$OUTPUT" | sed -n '/^WAITING ON YOU/,/^---/p' | grep -q "#1889" && fail "split lane wrongly counted as waiting"

# Working lane with its PR sub-row.
echo "$OUTPUT" | grep -q "#1945 building .* - Workshop part 1: real build data" || fail "working lane row missing or wrong"
echo "$OUTPUT" | grep -q -- "-- PR #1950" || fail "PR sub-row missing"

# Recently-done lane appears; day-old done lane is omitted.
echo "$OUTPUT" | grep -q "#1943 done .* - Workshop: asking Moss for a module" || fail "recent done lane missing"
echo "$OUTPUT" | grep -q "#1800" && fail "day-old done lane should have been omitted"

# Footer: agent starts, run started, and only the recent alarm.
echo "$OUTPUT" | grep -q "^Agent starts 6" || fail "agent starts footer row missing"
echo "$OUTPUT" | grep -q "^Run started " || fail "run started footer row missing"
echo "$OUTPUT" | grep -q "ALARM fleet code has uncommitted edits" || fail "recent alarm missing"
echo "$OUTPUT" | grep -q "stale problem" && fail "stale alarm should have been omitted"

echo "PASS: fleet-menu.mjs output matches all checked rules"
