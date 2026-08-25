#!/usr/bin/env bash
# Tests for tick.sh. Everything external is stubbed with PATH
# shims (fleetctl, herdr, gh, claude, needs-ben, git ls-remote), so no network,
# no real agents, and no real record writes happen here.
set -euo pipefail

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tick="$tool_root/tick.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/logs" "$tmp/needs-ben/queue" "$tmp/needs-ben/sent" "$tmp/needs-ben/replies"

export SHIM_LOG_DIR="$tmp/logs"

# The tooling now lives in its own repo, so tick.sh is told which product checkout to
# work in. A throwaway one stands in for it here.
fake_repo="$tmp/repo"
mkdir -p "$fake_repo"
git -C "$fake_repo" init -q
git -C "$fake_repo" remote add origin https://github.com/example/example.git
# The reap safety check is a script the product repo provides; a stand-in answers here.
mkdir -p "$fake_repo/scripts"
cat >"$fake_repo/scripts/worktree-reapable.sh" <<'REAP'
#!/usr/bin/env bash
echo "REAPABLE"
REAP
chmod +x "$fake_repo/scripts/worktree-reapable.sh"
real_git="$(command -v git)"

# --- PATH shims ---------------------------------------------------------------

cat >"$tmp/bin/fleetctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/fleetctl.log"
EOF

cat >"$tmp/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/herdr.log"
no_agents='{"result":{"agents":[]}}'
case "$1 $2" in
  "agent list")
    printf '%s\n' "${HERDR_AGENTS_JSON:-$no_agents}"
    exit "${HERDR_AGENT_LIST_EXIT:-0}"
    ;;
  "pane list")  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1"}]}}' ;;
  "agent start") exit "${HERDR_AGENT_START_EXIT:-0}" ;;
  # A non-dry dispatch really asks for a pane; hand one back so a live test
  # can walk the whole spawn path instead of failing at "no pane".
  "tab create") printf '%s\n' '{"result":{"root_pane":{"pane_id":"w1:p9"}}}' ;;
esac
EOF

cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/gh.log"
no_items='{"items":[]}'
no_fields='{"fields":[{"id":"field_status","name":"Status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_inprogress","name":"In progress"},{"id":"opt_done","name":"Done"}]}]}'
case "$1 $2" in
  "project item-list")
    [ -n "${GH_PROJECT_LIST_STDERR:-}" ] && echo "${GH_PROJECT_LIST_STDERR}" >&2
    # An explicitly empty value means "GitHub gave nothing back" and must
    # stay empty, not fall back to the default empty board.
    printf '%s\n' "${GH_PROJECT_JSON-$no_items}"
    ;;
  "project view")
    [ -n "${GH_PROJECT_VIEW_STDERR:-}" ] && echo "${GH_PROJECT_VIEW_STDERR}" >&2
    printf '%s\n' "${GH_PROJECT_VIEW_ID-proj_1}"
    exit "${GH_PROJECT_VIEW_EXIT:-0}"
    ;;
  "project field-list")
    [ -n "${GH_PROJECT_FIELDS_STDERR:-}" ] && echo "${GH_PROJECT_FIELDS_STDERR}" >&2
    printf '%s\n' "${GH_PROJECT_FIELDS_JSON-$no_fields}"
    exit "${GH_PROJECT_FIELDS_EXIT:-0}"
    ;;
  "project item-edit")
    [ -n "${GH_ITEM_EDIT_STDERR:-}" ] && echo "${GH_ITEM_EDIT_STDERR}" >&2
    exit "${GH_ITEM_EDIT_EXIT:-0}"
    ;;
  "issue develop")     printf '%s\n' "${GH_ISSUE_BRANCHES:-}" ;;
  "issue view")
    [ -n "${GH_ISSUE_VIEW_STDERR:-}" ] && echo "${GH_ISSUE_VIEW_STDERR}" >&2
    case "$*" in
      *"--json comments"*) printf '%s\n' "${GH_SPEC_COMMENT_COUNT:-0}" ;;
      *) printf '%s\n' "${GH_ISSUE_STATE-OPEN}" ;;
    esac
    exit "${GH_ISSUE_VIEW_EXIT:-0}"
    ;;
  "issue close")
    [ -n "${GH_ISSUE_CLOSE_STDERR:-}" ] && echo "${GH_ISSUE_CLOSE_STDERR}" >&2
    exit "${GH_ISSUE_CLOSE_EXIT:-0}"
    ;;
  "issue create")
    [ -n "${GH_ISSUE_CREATE_STDERR:-}" ] && echo "${GH_ISSUE_CREATE_STDERR}" >&2
    printf '%s\n' "${GH_ISSUE_CREATE_URL:-}"
    exit "${GH_ISSUE_CREATE_EXIT:-0}"
    ;;
  "pr list")           printf '%s\n' "${GH_PR_LIST:-}" ;;
  "pr checks")
    [ -n "${GH_CHECKS_STDERR:-}" ] && echo "${GH_CHECKS_STDERR}" >&2
    printf '%s\n' "${GH_CHECKS-[]}"
    exit "${GH_CHECKS_EXIT:-0}"
    ;;
  "pr view")
    case "$*" in
      *"--json files"*)      printf '%s\n' "${GH_PR_FILES:-}" ;;
      *"--json comments"*)   printf '%s\n' "${GH_PR_COMMENTS:-}" ;;
      *"--json headRefOid"*) printf '%s\n' "${GH_PR_SHA:-}" ;;
      *"--json mergeStateStatus"*) printf '%s\n' "${GH_PR_MERGE_STATE:-CLEAN}" ;;
      *"--json state"*)
        [ -n "${GH_PR_STATE_STDERR:-}" ] && echo "${GH_PR_STATE_STDERR}" >&2
        printf '%s\n' "${GH_PR_STATE:-OPEN}"
        exit "${GH_PR_STATE_EXIT:-0}"
        ;;
    esac ;;
  "pr merge")
    [ -n "${GH_MERGE_STDERR:-}" ] && echo "${GH_MERGE_STDERR}" >&2
    exit "${GH_MERGE_EXIT:-0}"
    ;;
  "run list")
    # The daemon reads this back through --jq '.[0].databaseId', so the
    # shim hands back the already-extracted id, same as the other --jq'd
    # calls above. An explicitly empty value means "no run found" and must
    # stay empty, not fall back to the default.
    [ -n "${GH_RUN_LIST_STDERR:-}" ] && echo "${GH_RUN_LIST_STDERR}" >&2
    printf '%s\n' "${GH_RUN_ID-9001}"
    ;;
  "api graphql")
    # The slim board read. Answers in the GraphQL page shape, built from the
    # same item-list style fixture (GH_PROJECT_JSON) the old call used, so
    # no fixture changes. Same stderr / empty-answer knobs as before.
    [ -n "${GH_PROJECT_LIST_STDERR:-}" ] && echo "${GH_PROJECT_LIST_STDERR}" >&2
    board="${GH_PROJECT_JSON-$no_items}"
    if [ -z "$board" ]; then exit 1; fi # "GitHub gave nothing back"
    jq -c '{data:{viewer:{projectV2:{items:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[.items[]? | {id:(.id // null), fieldValueByName:{name:(.status // null)}, content:{__typename:(.content.type // "Issue"), number:.content.number, title:.content.title, body:(.content.body // ""), labels:{nodes:[(.labels // [])[] | {name:.}]}, repository:{nameWithOwner:(.content.repository // "motioneso/fake")}}}]}}}}}' <<<"$board"
    ;;
  "api "*)
    # $2 is a REST path (repos/OWNER/NAME/commits/SHA/check-runs), not a
    # fixed subcommand token, so it is matched as a glob within the case.
    # Several REST reads share the same paths, so which answer to hand back
    # is picked by the --jq program in the call. Order matters below:
    # ".merged" is a leading substring of ".mergeable_state", so the
    # mergeable-state pattern must be tried first. An unset value answers
    # empty, which sends the daemon to its old-door fallback.
    [ -n "${GH_API_STDERR:-}" ] && echo "${GH_API_STDERR}" >&2
    case "$*" in
      *check-runs*)       printf '%s\n' "${GH_API_CHECKS:-}" ;;
      *".head.sha"*)      printf '%s\n' "${GH_API_PR_SHA:-}" ;;
      *mergeable_state*)  printf '%s\n' "${GH_API_PR_MERGE_STATE:-}" ;;
      *".merged"*)        printf '%s\n' "${GH_API_PR_STATE:-}" ;;
      *"/issues/"*)       printf '%s\n' "${GH_API_ISSUE_STATE:-}" ;;
      *)                  printf '%s\n' "${GH_API_CHECKS:-}" ;;
    esac
    exit "${GH_API_EXIT:-0}"
    ;;
esac
EOF

cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude called" >> "$SHIM_LOG_DIR/claude.log"
# The prompt is the sole argument; recorded so a test can check exactly what
# was offered as an answer (e.g. that RESUME was left out).
printf '%s\n' "$*" >> "$SHIM_LOG_DIR/claude-prompts.log"
printf '=====\n' >> "$SHIM_LOG_DIR/claude-prompts.log"
# CLAUDE_EXIT, if set, makes the command itself fail (wrong PATH, expired
# login) -- distinct from the model answering with a strange, unparseable
# ruling, which is CLAUDE_ANSWER set to something odd instead.
if [ -n "${CLAUDE_EXIT:-}" ] && [ "${CLAUDE_EXIT:-0}" != "0" ]; then
  echo "simulated failure" >&2
  exit "$CLAUDE_EXIT"
fi
# CLAUDE_ANSWER_QUEUE, if set, names a file with one answer per line; each
# call consumes the next line, so a test can script a sequence of answers
# across several ticks. Falls back to the fixed CLAUDE_ANSWER otherwise.
if [ -n "${CLAUDE_ANSWER_QUEUE:-}" ] && [ -s "$CLAUDE_ANSWER_QUEUE" ]; then
  next="$(head -n1 "$CLAUDE_ANSWER_QUEUE")"
  tail -n +2 "$CLAUDE_ANSWER_QUEUE" > "$CLAUDE_ANSWER_QUEUE.rest"
  mv "$CLAUDE_ANSWER_QUEUE.rest" "$CLAUDE_ANSWER_QUEUE"
  printf '%s\n' "$next"
else
  # Dash, not colon-dash: CLAUDE_ANSWER explicitly set to "" means the model
  # answered with nothing, and must stay empty; only an unset var means the
  # test didn't care, and falls back to PARK.
  printf '%s\n' "${CLAUDE_ANSWER-PARK}"
fi
EOF

cat >"$tmp/bin/other-judge" <<'EOF'
#!/usr/bin/env bash
echo "other-judge called" >> "$SHIM_LOG_DIR/other-judge.log"
printf '%s\n' "PARK"
EOF

cat >"$tmp/bin/needs-ben" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SHIM_LOG_DIR/needs-ben.log"
EOF

# Match on the git SUBCOMMAND, never the whole argument string: paths in the
# arguments (this repo lives under .claude/worktrees/) would otherwise trip the
# worktree pattern and swallow unrelated calls like git config.
cat >"$tmp/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-C" ]; then sub="\${3:-}"; else sub="\${1:-}"; fi
case "\$sub" in
  ls-remote) printf '%s\n' "\${GIT_LSREMOTE_OUT:-}"; exit 0 ;;
  show-ref)  exit "\${GIT_SHOWREF_EXIT:-1}" ;;
  # The mid-edit guard at tick top asks about the TOOLING checkout, which
  # during a test run genuinely has edits in flight; the shim answers for
  # it so tests control the answer (empty = clean).
  status)    printf '%s\n' "\${GIT_STATUS_OUT:-}"; exit 0 ;;
  worktree)
    echo "\$*" >> "\$SHIM_LOG_DIR/git.log"
    if [ -n "\${GIT_WORKTREE_ADD_EXIT:-}" ] && [ "\${GIT_WORKTREE_ADD_EXIT:-0}" != "0" ]; then
      printf '%s\n' "\${GIT_WORKTREE_ADD_STDERR:-simulated worktree failure}" >&2
      exit "\$GIT_WORKTREE_ADD_EXIT"
    fi
    exit 0
    ;;
  *)         exec "$real_git" "\$@" ;;
esac
EOF

chmod +x "$tmp/bin/"*

# --- helpers --------------------------------------------------------------------

template="$tmp/brief-template.md"
printf '%s\n' '# Build issue ${ISSUE}' 'Tier: ${TIER}. Branch: ${BRANCH}. Worktree: ${WORKTREE}.' > "$template"
meminfo_ok="$tmp/meminfo-ok"
printf 'MemTotal:       65536000 kB\nMemAvailable:   32768000 kB\n' > "$meminfo_ok"

now_iso="$(date -Iseconds)"

new_state() { # fresh state dir, echoes its path
  local d
  d="$(mktemp -d "$tmp/state-XXXX")"
  mkdir -p "$d/tasks"
  echo "$d"
}

write_record() { # <state-dir> <issue> <json>
  printf '%s\n' "$3" > "$1/tasks/$2.json"
}

clear_logs() {
  rm -f "$SHIM_LOG_DIR"/*.log
}

run_tick() { # <state-dir> [extra env KEY=VAL...]; dry-run unless FLEET_DRY_RUN passed
  local state="$1"
  shift
  # Overnight hours pinned to start==end (never overnight) so the suite is not
  # time-of-day dependent; a test that wants the overnight gate passes its own
  # FLEET_OVERNIGHT_* values, which win because env applies them last.
  PATH="$tmp/bin:$PATH" \
    JARV1S_FLEET_STATE="$state" \
    JARV1S_REPO="$fake_repo" \
    FLEET_BRIEF_TEMPLATE="$template" \
    NEEDS_BEN_DIR="$tmp/needs-ben" \
    FLEET_MEMINFO="$meminfo_ok" \
    FLEET_BOARD_CHECK_SECONDS=0 \
    FLEET_OVERNIGHT_START_HOUR=0 \
    FLEET_OVERNIGHT_END_HOUR=0 \
    FLEET_DRY_RUN=1 \
    env "$@" "$tick"
}

run_tick_live() { # non-dry: everything still stubbed via PATH shims
  local state="$1"
  shift
  PATH="$tmp/bin:$PATH" \
    JARV1S_FLEET_STATE="$state" \
    JARV1S_REPO="$fake_repo" \
    FLEET_BRIEF_TEMPLATE="$template" \
    NEEDS_BEN_DIR="$tmp/needs-ben" \
    FLEET_MEMINFO="$meminfo_ok" \
    FLEET_BOARD_CHECK_SECONDS=0 \
    FLEET_OVERNIGHT_START_HOUR=0 \
    FLEET_OVERNIGHT_END_HOUR=0 \
    env "$@" "$tick"
}

pass() { echo "PASS: $1"; }

# Mirrors tick.sh's own budget_cutoff_epoch() (window starts at the most
# recent 18:00 local time), so a test can seed the spawn counter file the
# same way the daemon itself would have written it.
budget_cutoff_epoch_test() {
  local day
  if [ "$(date +%H)" -ge 18 ]; then day="$(date +%F)"; else day="$(date -d yesterday +%F)"; fi
  date -d "$day 18:00" +%s
}

# --- 1. STOP file: exit 0 without acting ------------------------------------------

state="$(new_state)"
write_record "$state" 101 '{"issue":101,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
touch "$state/STOP"
out="$(run_tick "$state")"
[ -z "$out" ]
pass "STOP file exits silently without acting"

# --- 2. queued dispatches when under cap ------------------------------------------

state="$(new_state)"
write_record "$state" 101 '{"issue":101,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q "DRY: git .*worktree add" <<<"$out"
grep -q "DRY: herdr agent start fleet-lane-101" <<<"$out"
grep -q "DRY: fleetctl set 101 status=building" <<<"$out"
pass "queued lane dispatches when under cap and budget"

# --- 3. queued does not dispatch at the lane cap -----------------------------------

state="$(new_state)"
for i in 1 2 3 4 5; do
  write_record "$state" "20$i" "{\"issue\":20$i,\"status\":\"building\",\"agent\":\"a$i\",\"relays\":0,\"updated_at\":\"$now_iso\"}"
done
write_record "$state" 101 '{"issue":101,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
if grep -q "worktree add" <<<"$out"; then false; fi
pass "queued lane does not dispatch when 5 lanes are live"

# --- 4. queued does not dispatch when the spawn budget is spent --------------------
#
# The nightly spawn count now lives in a small counter file (.spawn-count),
# not a scan of the whole log -- seeded here the same way tick.sh itself
# would write it, keyed to the same 18:00 budget-window start.

state="$(new_state)"
write_record "$state" 101 '{"issue":101,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
printf '%s 30\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
out="$(run_tick "$state")"
if grep -q "worktree add" <<<"$out"; then false; fi
pass "queued lane does not dispatch when 30 spawns already happened tonight"

# --- 5. qa-green security tier merges on standing authority, loudly flagged --------

state="$(new_state)"
write_record "$state" 105 '{"issue":105,"status":"qa-green","tier":"security","pr":55,"relays":0,"spec":"docs/x.md"}'
out="$(GH_PR_FILES="apps/api/src/thing.ts" GH_PR_COMMENTS="" run_tick "$state")"
grep -q "morning board" <<<"$out"
grep -q "DRY: gh pr merge 55 --squash --auto" <<<"$out"
if grep -q "fleetctl set 105 status=blocked" <<<"$out"; then false; fi
pass "qa-green security tier merges without a sign-off pause, flagged for the morning board"

# --- 6. qa-green user-facing without live-path proof parks --------------------------

state="$(new_state)"
write_record "$state" 106 '{"issue":106,"status":"qa-green","tier":"routine","pr":56,"relays":0,"spec":"docs/x.md"}'
out="$(GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS="looks good to me" run_tick "$state")"
grep -q "code-complete, unverified" <<<"$out"
if grep -q "pr merge" <<<"$out"; then false; fi
pass "qa-green user-facing PR without proof parks as code-complete, unverified"

# --- 6a. qa-green user-facing: the phrase inside a reviewer's sentence does not count ---

state="$(new_state)"
write_record "$state" 111 '{"issue":111,"status":"qa-green","tier":"routine","pr":58,"relays":0,"spec":"docs/x.md"}'
out="$(GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS="there is no live-path proof on this PR yet" run_tick "$state")"
grep -q "code-complete, unverified" <<<"$out"
if grep -q "pr merge" <<<"$out"; then false; fi
pass "qa-green: the phrase inside a reviewer's sentence does not count as proof"

# --- 6b. qa-green user-facing WITH an anchored proof comment merges on auto --------

state="$(new_state)"
write_record "$state" 107 '{"issue":107,"status":"qa-green","tier":"routine","pr":57,"relays":0,"spec":"docs/x.md"}'
out="$(GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS=$'looks good to me\nLIVE-PATH PROOF\nExercised on the dev box, screenshots attached.' run_tick "$state")"
grep -q "DRY: gh pr merge 57 --squash --auto" <<<"$out"
pass "qa-green with an anchored live-path proof comment enables auto-merge (squash, never admin)"

# --- 7. relays >= 2 tries an automatic re-slice, parks when it cannot ---------------

state="$(new_state)"
write_record "$state" 110 "{\"issue\":110,\"status\":\"building\",\"agent\":\"a\",\"relays\":2,\"spec\":\"https://github.com/motioneso/fake/issues/110\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
grep -q "re-slice draft for lane 110" <<<"$out"
grep -q "needs re-slice" <<<"$out"
pass "a lane relayed twice tries the automatic re-slice, and parks to ask when it cannot"

# --- 7b. a lane that IS a re-slice never re-slices again: it resumes instead --------

state="$(new_state)"
mkdir -p "$state/briefs"
echo "brief" > "$state/briefs/brief-113-build.md"
write_record "$state" 113 "{\"issue\":113,\"status\":\"building\",\"agent\":\"a\",\"relays\":2,\"worktree\":\"$state\",\"spec\":\"https://github.com/motioneso/fake/issues/113\",\"updated_at\":\"$now_iso\"}"
printf '%s\n' '{"items":[{"id":"it1","status":"Ready","content":{"type":"Issue","number":113,"title":"x","body":"Re-sliced by the fleet daemon from #99.","repository":"motioneso/fake"}}]}' > "$state/board-items-full.json"
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
if grep -q "needs re-slice" <<<"$out"; then false; fi
grep -q "not slicing again" <<<"$out"
grep -q "DRY: fleetctl set 113 relay_cap_waived=1" <<<"$out"
grep -q "relay: respawned build agent a to continue after relay 2" <<<"$out"
pass "a re-sliced lane that relays out again resumes on Ben's standing answer instead of parking"

# --- 7c. a lane with no issue-link spec parks and asks instead of guessing the repo -

state="$(new_state)"
write_record "$state" 115 "{\"issue\":115,\"status\":\"building\",\"agent\":\"a\",\"relays\":2,\"spec\":\"docs/x.md\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
grep -q "repo is unknown" <<<"$out"
grep -q "needs re-slice" <<<"$out"
pass "a lane whose spec is not an issue link parks and asks instead of guessing the repo"

# --- 7d. a lane already re-sliced once never cuts a second follow-up ----------------

state="$(new_state)"
write_record "$state" 116 "{\"issue\":116,\"status\":\"building\",\"agent\":\"a\",\"relays\":2,\"blocked_reason\":\"re-sliced on Ben's word: remaining work is issue #900\",\"spec\":\"https://github.com/motioneso/fake/issues/116\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
if grep -q "needs re-slice" <<<"$out"; then false; fi
grep -q "already re-sliced once" <<<"$out"
grep -q "continuing on Ben's standing 'resume'" <<<"$out"
pass "a lane already re-sliced once refuses a second follow-up and resumes instead"

# --- 7f. a lane whose relay cap was already waived is never re-examined -------------

state="$(new_state)"
write_record "$state" 118 "{\"issue\":118,\"status\":\"building\",\"agent\":\"a\",\"relays\":3,\"relay_cap_waived\":1,\"spec\":\"https://github.com/motioneso/fake/issues/118\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
if grep -q "not slicing again" <<<"$out"; then false; fi
if grep -q "needs re-slice" <<<"$out"; then false; fi
pass "a waived relay cap stays waived: no re-slice attempt, no park, on every later relay"

# --- 7e. a lane parked as re-sliced is finished: no deputy, no phone ----------------

state="$(new_state)"
write_record "$state" 117 '{"issue":117,"status":"blocked","tier":"routine","blocked_reason":"re-sliced automatically: remaining work is issue #901","relays":2}'
out="$(run_tick "$state")"
if grep -qi "deputy for lane 117" <<<"$out"; then false; fi
if grep -q "DRY: needs-ben fleet-daemon issue 117" <<<"$out"; then false; fi
pass "a lane parked as re-sliced stays quiet: no deputy resume, no phone ping"

# --- 7g0. a finished agent still holds its name: close it, dispatch next tick -------
# (2026-08-25, lane 1951: herdr refuses to start a new agent while the finished
# one is registered, so the old expectation of a same-tick spawn was wrong.)

state="$(new_state)"
write_record "$state" 118 '{"issue":118,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-118","agent_status":"done","pane_id":"w1:p9"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "already live" <<<"$out"; then false; fi
grep -q "closed the leftover agent window fleet-lane-118" <<<"$out"
if grep -q "DRY: herdr agent start fleet-lane-118" <<<"$out"; then false; fi
pass "a finished agent still holding the name is closed first; dispatch follows next tick"

# --- 7g. lingering finished panes flagged idle do not freeze the next QA round -----
# Seen live 2026-08-25: the terminal manager's done/idle flag is unstable (a
# finished agent read "done" one minute and "idle" the next), so at pr-open --
# where writing the status was the previous agent's last act -- leftover panes
# from earlier stages must never block the reviewer.

state="$(new_state)"
write_record "$state" 119 '{"issue":119,"status":"pr-open","tier":"routine","pr":119,"branch":"feat/119","agent":"fleet-fix-119-r1","reviewer":"fleet-qa-119-r1","qa_rounds":1,"qa_fix_rounds":1,"relays":0}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-119","agent_status":"idle","pane_id":"w1:p1"},{"name":"fleet-qa-119-r1","agent_status":"idle","pane_id":"w1:p2"},{"name":"fleet-fix-119-r1","agent_status":"idle","pane_id":"w1:p3"}]}}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: herdr agent start fleet-qa-119-r2" <<<"$out"
pass "lingering finished panes do not block the next QA round at pr-open"

# --- 7h. at a red review the finished builder's lingering pane does not block the fix --

state="$(new_state)"
write_record "$state" 120 '{"issue":120,"status":"qa-red","tier":"routine","agent":"fleet-lane-120","qa_rounds":1,"relays":0}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-120","agent_status":"idle","pane_id":"w1:p1"},{"name":"fleet-qa-120-r1","agent_status":"idle","pane_id":"w1:p2"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: herdr agent start fleet-fix-120-qa-r1" <<<"$out"
pass "the finished builder's lingering pane does not block the fix agent"

# --- 7i. a pane already holding the exact next name still blocks a double spawn ----

state="$(new_state)"
write_record "$state" 121 '{"issue":121,"status":"pr-open","tier":"routine","pr":121,"branch":"feat/121","qa_rounds":1,"relays":0}'
agents_json='{"result":{"agents":[{"name":"fleet-qa-121-r2","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "DRY: herdr agent start fleet-qa-121-r2" <<<"$out"; then false; fi
grep -q "not spawning QA: fleet-qa-121-r2 already has a pane" <<<"$out"
pass "a pane already holding the exact next reviewer name still blocks a double spawn"

# --- 8. deputy is ON by default and rules at once (Ben's standing rule 2026-08-24) --

state="$(new_state)"
write_record "$state" 108 '{"issue":108,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
printf 'until=%s\n' "$(date -d '1 hour ago' +%Y-%m-%dT%H:%M)" > "$state/DEPUTY"
out="$(run_tick "$state")"
grep -q "DRY: claude -p \[deputy for lane 108" <<<"$out"
if grep -q "DRY: needs-ben" <<<"$out"; then false; fi
pass "deputy is on by default, rules immediately, and Ben's phone stays quiet"

# --- 8b. deputyEnabled false is the only off switch; then Ben is the judge ----------

printf '{"deputyEnabled": false}\n' > "$state/settings.json"
out="$(run_tick "$state")"
if grep -qi "deputy for lane" <<<"$out"; then false; fi
grep -q "DRY: needs-ben fleet-daemon issue 108: stuck on a decision" <<<"$out"
pass "an explicit deputyEnabled false turns the deputy off and asks Ben directly"

# --- 8d. a stamped deputy PARK is terminal: only then does Ben's phone ring ---------

printf '{}\n' > "$state/settings.json"
write_record "$state" 108 '{"issue":108,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","deputy_reason":"stuck on a decision","deputy_answer":"PARK","deputy_attempts":1,"relays":0}'
out="$(run_tick "$state")"
if grep -qi "deputy for lane" <<<"$out"; then false; fi
grep -q "DRY: needs-ben fleet-daemon issue 108: stuck on a decision" <<<"$out"
pass "a stamped deputy PARK is terminal: no re-ask, and only then does Ben's phone ring"

# --- 8c. the judgment command is swappable, no model name baked in ------------------

write_record "$state" 108 '{"issue":108,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
out="$(run_tick "$state" FLEET_JUDGE_CMD='some-other-provider run')"
grep -q "DRY: some-other-provider run \[deputy for lane 108" <<<"$out"
if grep -qiE "claude-(fable|opus|sonnet|haiku)" <<<"$out"; then false; fi
pass "deputy honours FLEET_JUDGE_CMD and pins no model name"

# --- 8i. overnight, a queued issue with no written plan stays queued ----------------

state="$(new_state)"
write_record "$state" 500 '{"issue":500,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/500"}'
out="$(run_tick "$state" FLEET_OVERNIGHT_START_HOUR=0 FLEET_OVERNIGHT_END_HOUR=24)"
grep -q "overnight rule: not dispatching" <<<"$out"
if grep -q "herdr agent start fleet-lane-500" <<<"$out"; then false; fi
pass "overnight, an issue with no written plan is not dispatched"

# --- 8j. overnight, a SPEC comment on the issue counts as the plan ------------------

state="$(new_state)"
write_record "$state" 500 '{"issue":500,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/500"}'
out="$(run_tick "$state" FLEET_OVERNIGHT_START_HOUR=0 FLEET_OVERNIGHT_END_HOUR=24 GH_SPEC_COMMENT_COUNT=1)"
grep -q "DRY: herdr agent start fleet-lane-500" <<<"$out"
pass "overnight, an issue comment starting with SPEC counts as the plan and dispatch goes ahead"

# --- 8k. overnight, a spec file in the repo counts as the plan ----------------------

state="$(new_state)"
write_record "$state" 501 '{"issue":501,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/501"}'
mkdir -p "$fake_repo/docs/specs"
echo "plan" > "$fake_repo/docs/specs/501.md"
out="$(run_tick "$state" FLEET_OVERNIGHT_START_HOUR=0 FLEET_OVERNIGHT_END_HOUR=24)"
grep -q "DRY: herdr agent start fleet-lane-501" <<<"$out"
pass "overnight, a spec file in the repo counts as the plan and dispatch goes ahead"

# --- 8e. a rate-limited check query reads as "GitHub refusing to answer", not "still running" -

state="$(new_state)"
write_record "$state" 130 '{"issue":130,"status":"pr-open","tier":"routine","pr":130,"relays":0}'
clear_logs
out="$(GH_CHECKS='' GH_CHECKS_STDERR='api.github.com: API rate limit exceeded for installation' run_tick "$state")"
grep -q "DRY: fleetctl log fleet ALARM: GitHub is refusing to answer" <<<"$out"
if grep -q "status=ci-red\|status=qa" <<<"$out"; then false; fi
pass "a rate-limited check query is read as GitHub refusing to answer, not still running"

# --- 8f. a starved tick skips remaining GitHub questions and touches no lane state -----

state="$(new_state)"
write_record "$state" 130 '{"issue":130,"status":"pr-open","tier":"routine","pr":130,"relays":0}'
write_record "$state" 131 '{"issue":131,"status":"qa-green","tier":"routine","pr":131,"relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_PR_FILES='apps/web/src/App.tsx' run_tick "$state")"
alarm_count="$(grep -c "ALARM: GitHub is refusing to answer" <<<"$out")"
[ "$alarm_count" -eq 1 ]
if grep -q "fleetctl set 131" <<<"$out"; then false; fi
pass "a starved tick skips the rest of that tick's GitHub questions, logged once, not once per lane"

# --- 8g. the REST door is asked first, and the old door only on REST failure -----------

state="$(new_state)"
write_record "$state" 132 '{"issue":132,"status":"pr-open","tier":"routine","pr":132,"branch":"feat/132","relays":0}'
clear_logs
out="$(GH_PR_SHA='deadbeef' GH_API_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-132-r1" <<<"$out"
if grep -q "pr checks" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "check results come from the REST door first; the old door is untouched when REST answers"

# --- 8h. a lane stuck a full hour in a moving state with no news raises the stillness alarm ---

state="$(new_state)"
stale_hour_iso="$(date -Iseconds -d '90 minutes ago')"
write_record "$state" 133 "{\"issue\":133,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":133,\"relays\":0,\"updated_at\":\"$stale_hour_iso\"}"
clear_logs
out="$(GH_PR_STATE='OPEN' run_tick "$state")"
grep -q "DRY: fleetctl log fleet ALARM: stillness" <<<"$out"
pass "a lane stuck a full hour with no news raises the stillness alarm"

state="$(new_state)"
recent_iso="$(date -Iseconds -d '5 minutes ago')"
write_record "$state" 134 "{\"issue\":134,\"status\":\"blocked\",\"tier\":\"routine\",\"blocked_reason\":\"parked for Ben\",\"relays\":0,\"updated_at\":\"$stale_hour_iso\"}"
clear_logs
out="$(run_tick "$state")"
if grep -q "ALARM: stillness" <<<"$out"; then false; fi
pass "a parked lane never raises the stillness alarm, however long it has been quiet"

# --- 9. intake adopts an issue with an open PR at pr-open ---------------------------

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":201,"title":"Add widget","body":"plain feature"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ISSUE_BRANCHES=$'feat/201-widget\trepo' GH_PR_LIST="77" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "add 201 spec=https://github.com/.*/issues/201 tier=routine" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 201 status=pr-open pr=77 branch=feat/201-widget" "$SHIM_LOG_DIR/fleetctl.log"
pass "intake adopts an issue with an open PR at pr-open"

# --- 10. intake adopts an issue with a branch but no PR at queued -------------------

state="$(new_state)"
clear_logs
# Real board value is "In progress" with a lowercase p; the match must not care.
project_json='{"items":[{"status":"In progress","labels":["task","fleet-run"],"content":{"type":"Issue","number":202,"title":"Fix export","body":"touches exports"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ISSUE_BRANCHES=$'fix/202-export\trepo' GH_PR_LIST="" CLAUDE_ANSWER="SENSITIVE" >/dev/null
grep -q "add 202 spec=https://github.com/.*/issues/202 tier=sensitive" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 202 branch=fix/202-export" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "resume brief" "$SHIM_LOG_DIR/fleetctl.log"
pass "intake adopts an issue with a branch but no PR at queued, marked for resume"

# --- 11. intake skips only a lane whose agent is live right now ---------------------

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":203,"title":"Tidy thing","body":"x"}}]}'
# Only one of the fleet's own agent-name patterns counts, and only as a
# whole token -- not any agent whose name happens to contain the digits.
agents_json='{"result":{"agents":[{"name":"fleet-lane-203","pane_id":"w1:p9"}]}}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" HERDR_AGENTS_JSON="$agents_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "log 203 intake skipped" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "add 203" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "intake skips a lane only while its agent is live, and logs it"

# --- 11b. Unit 7 bullet 2: a same-digits agent name does not count as a match -------
# The near-miss from the review: issue 18 must not be starved by an agent
# working issue 1834 just because "18" is a substring of "1834".

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":18,"title":"Small fix","body":"x"}}]}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-1834","pane_id":"w1:p9"}]}}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" HERDR_AGENTS_JSON="$agents_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
if grep -q "log 18 intake skipped" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "add 18" "$SHIM_LOG_DIR/fleetctl.log"
pass "an agent working issue 1834 does not starve issue 18 just because 18 is a substring of 1834"

# --- 12. deputy CAN sign off a security-tier merge ----------------------------------

state="$(new_state)"
clear_logs
write_record "$state" 301 '{"issue":301,"status":"blocked","tier":"security","pr":88,"blocked_reason":"security tier: merge needs Ben sign-off","relays":0}'
printf 'until=%s\n' "$(date -d '1 hour' +%Y-%m-%dT%H:%M)" > "$state/DEPUTY"
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 301: security tier: merge needs Ben sign-off" > "$tmp/needs-ben/sent/entry-301.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-301.msg"
run_tick_live "$state" CLAUDE_ANSWER="MERGE" >/dev/null
grep -q "pr merge 88 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "set 301 status=merging" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "DEPUTY security merge sign-off" "$SHIM_LOG_DIR/fleetctl.log"
pass "deputy can sign off a security-tier merge, flagged for the morning board"

# --- 13. deputy MERGE that would cross the hard floor resolves to park ---------------

state="$(new_state)"
clear_logs
write_record "$state" 302 '{"issue":302,"status":"blocked","tier":"routine","pr":89,"blocked_reason":"code-complete, unverified","relays":0}'
printf 'until=%s\n' "$(date -d '1 hour' +%Y-%m-%dT%H:%M)" > "$state/DEPUTY"
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 302: code-complete, unverified" > "$tmp/needs-ben/sent/entry-302.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-302.msg"
run_tick_live "$state" CLAUDE_ANSWER="MERGE" >/dev/null
if grep -q "pr merge 89" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -q "MERGE refused" "$SHIM_LOG_DIR/fleetctl.log"
pass "deputy cannot merge past the live-path check; the lane stays parked"

# --- 14. settings.json is read, and the environment still wins ---------------------

state="$(new_state)"
write_record "$state" 401 '{"issue":401,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
printf '{"laneCap": 0}\n' > "$state/settings.json"
out="$(run_tick "$state")"
if grep -q "worktree add" <<<"$out"; then false; fi
pass "laneCap from settings.json is honoured (0 lanes means nothing dispatches)"

out="$(run_tick "$state" FLEET_LANE_CAP=1)"
grep -q "DRY: herdr agent start fleet-lane-401" <<<"$out"
pass "an environment variable still overrides the settings file"

# --- 14b. judgeCmd from settings drives judgment calls ------------------------------

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 402 "{\"issue\":402,\"status\":\"building\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
printf '{"judgeCmd": "other-judge run"}\n' > "$state/settings.json"
run_tick_live "$state" >/dev/null
grep -q "other-judge called" "$SHIM_LOG_DIR/other-judge.log"
pass "judgeCmd from settings.json drives the dead-lane judgment call"

# --- 14c. a malformed settings file falls back to the built-in numbers --------------

state="$(new_state)"
write_record "$state" 403 '{"issue":403,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
printf '{"laneCap": "lots"}\n' > "$state/settings.json"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-403" <<<"$out"
pass "a non-numeric laneCap falls back to the built-in cap instead of breaking the tick"

# --- 15. a paused lane is skipped entirely, including the dead-lane check ----------

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 501 "{\"issue\":501,\"status\":\"building\",\"agent\":\"gone-agent\",\"paused\":true,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(run_tick "$state")"
if grep -qE "judgment for lane 501|set 501 status=blocked" <<<"$out"; then false; fi
pass "a paused lane survives past the dead-lane threshold untouched"

# --- 15b. a paused queued lane is not dispatched ------------------------------------

state="$(new_state)"
write_record "$state" 502 '{"issue":502,"status":"queued","tier":"routine","paused":true,"relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
if grep -q "worktree add" <<<"$out"; then false; fi
pass "a paused queued lane spawns nothing"

# --- 15c. the brief template teaches agents what a pause is, and renders ------------

grep -q "pause" "$tool_root/brief-template.md"
if grep -q '{{' "$tool_root/brief-template.md"; then false; fi
pass "brief template carries the pause rule and only placeholders the renderer replaces"

# --- 16. below the memory floor, no agent starts and the refusal is logged ---------

state="$(new_state)"
write_record "$state" 601 '{"issue":601,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
meminfo_low="$tmp/meminfo-low"
printf 'MemTotal:       65536000 kB\nMemAvailable:    1048576 kB\n' > "$meminfo_low"
out="$(run_tick "$state" FLEET_MEMINFO="$meminfo_low")"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "free memory" <<<"$out"
pass "below the 4 GB floor nothing spawns and the refusal is logged in plain English"

# --- 16b. an unreadable memory source fails open ------------------------------------

out="$(run_tick "$state" FLEET_MEMINFO="$tmp/does-not-exist")"
grep -q "DRY: herdr agent start fleet-lane-601" <<<"$out"
pass "an unreadable memory source does not stop the fleet"

# --- 16c. the memory floor is settable from the settings file, and env still wins ---

state="$(new_state)"
write_record "$state" 602 '{"issue":602,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
printf '{"memoryFloorMb":60000}\n' > "$state/settings.json"
out="$(run_tick "$state")"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "60000 MB floor" <<<"$out"
pass "a floor set in the settings file is honoured, so it is tunable without editing the unit"

out="$(run_tick "$state" FLEET_MEMORY_FLOOR_MB=1)"
grep -q "DRY: herdr agent start fleet-lane-602" <<<"$out"
pass "a floor pinned in the environment beats the settings file, like every other setting"

printf '{"memoryFloorMb":0}\n' > "$state/settings.json"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-602" <<<"$out"
pass "a floor of zero in the settings file turns the check off"

# --- 17. each kind of work spawns on its configured model and effort ----------------

state="$(new_state)"
write_record "$state" 701 '{"issue":701,"status":"queued","tier":"security","relays":0,"spec":"docs/x.md"}'
printf '{"buildModels":{"security":{"model":"model-x","effort":"high"}}}\n' > "$state/settings.json"
out="$(run_tick "$state")"
grep -q -- "--model model-x --effort high" <<<"$out"
pass "a security-tier lane spawns on the model and effort configured for security work"

# --- 17a2. each kind of work also names the program that runs it --------------------

state="$(new_state)"
write_record "$state" 703 '{"issue":703,"status":"queued","tier":"security","relays":0,"spec":"docs/x.md"}'
printf '{"buildModels":{"security":{"tool":"codex","model":"model-y","effort":"high"}}}\n' > "$state/settings.json"
out="$(run_tick "$state")"
grep -q -- "--kind codex" <<<"$out"
grep -q -- "-m model-y -c model_reasoning_effort=high" <<<"$out"
pass "a lane configured for another program launches that program with its own flags"

# --- 17a3. lane agents open in their own tab, not wherever a person is working ------

state="$(new_state)"
write_record "$state" 704 '{"issue":704,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q "in tab Fleet Agents" <<<"$out"
pass "a lane agent opens in the shared agents tab"

# --- 17b. no configuration at all means no model flag, not a baked-in name ----------

state="$(new_state)"
write_record "$state" 702 '{"issue":702,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-702" <<<"$out"
if grep -q -- "--model" <<<"$out"; then false; fi
pass "with no settings and no env, the spawn omits the model flag entirely"

# --- 17b2. a model pinned by hand does not inherit an effort meant for another ------

state="$(new_state)"
write_record "$state" 703 '{"issue":703,"status":"queued","tier":"security","relays":0,"spec":"docs/x.md"}'
printf '{"buildModels":{"security":{"model":"model-x","effort":"high"}}}\n' > "$state/settings.json"
out="$(run_tick "$state" FLEET_BUILD_MODEL=pinned-model)"
grep -q -- "--model pinned-model" <<<"$out"
if grep -q -- "--effort" <<<"$out"; then false; fi
pass "pinning only the model drops the settings file's effort instead of mispairing them"

out="$(run_tick "$state" FLEET_BUILD_MODEL=pinned-model FLEET_BUILD_EFFORT=low)"
grep -q -- "--model pinned-model --effort low" <<<"$out"
pass "pinning both the model and the effort uses exactly what was pinned"

# --- 17c. no model name appears in the daemon's own code ----------------------------

if grep -riE 'sonnet|opus|haiku|fable|gpt-[0-9]' "$tool_root/tick.sh" "$tool_root/fleetctl.mjs"; then false; fi
pass "the daemon and the state CLI contain no model names; names are data in settings"

# --- 18. a lane's outstanding question reaches the lane record ----------------------

state="$(new_state)"
write_record "$state" 801 '{"issue":801,"status":"blocked","tier":"routine","blocked_reason":"needs a schema decision","deputy_reason":"needs a schema decision","deputy_answer":"PARK","relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: needs-ben fleet-daemon issue 801: needs a schema decision" <<<"$out"
grep -q "DRY: fleetctl set 801 question=needs a schema decision questionAskedAt=" <<<"$out"
pass "filing a question for Ben also copies it onto the lane record"

# --- 18b. an existing question is not re-stamped every tick -------------------------

echo "issue 801: needs a schema decision" > "$tmp/needs-ben/sent/entry-801.msg"
out="$(run_tick "$state")"
if grep -q "set 801 question=" <<<"$out"; then false; fi
pass "a question already on file is not re-stamped, so its clock stays honest"

# --- 18c. a NEW question on a lane that already asked one refreshes the clock ------
# The asked-at stamp is what ages out stale replies (49f); a lane re-parked on a
# different question must move it forward.

out="$(run_tick "$state" <<<"" )"
: # same state dir: entry-801.msg says "needs a schema decision"
write_record "$state" 801 '{"issue":801,"status":"blocked","tier":"routine","blocked_reason":"a wholly new question","deputy_reason":"a wholly new question","deputy_answer":"PARK","relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 801 question=a wholly new question questionAskedAt=" <<<"$out"
pass "a lane re-parked on a different question gets a fresh asked-at stamp"

# --- 19. every lane status has a dry-run proof --------------------------------------

# The fixture for each status forces the next action where that status has one. The
# dry-run output is the proof of the decision only: it does not prove the external
# command would succeed.
state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 901 "{\"issue\":901,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(run_tick "$state")"
grep -q "DRY: claude -p \[judgment for lane 901" <<<"$out"
pass "building status asks for dead-lane judgment"

state="$(new_state)"
write_record "$state" 902 '{"issue":902,"status":"pr-open","tier":"routine","pr":902,"branch":"feat/902","relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-902-r1" <<<"$out"
grep -q "DRY: fleetctl set 902 status=qa" <<<"$out"
pass "pr-open status starts the first QA round after green checks"

state="$(new_state)"
write_record "$state" 903 '{"issue":903,"status":"ci-red","tier":"routine","pr":903,"relays":0}'
printf '{"ts":"%s","issue":903,"msg":"ci-red: failing checks: lint"}\n' "$now_iso" > "$state/log.jsonl"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-fix-903-ci-r1" <<<"$out"
grep -q "DRY: fleetctl set 903 agent=fleet-fix-903-ci-r1 ci_fix_rounds=+1" <<<"$out"
pass "ci-red status dispatches a fix agent instead of waiting for nobody"

state="$(new_state)"
write_record "$state" 904 '{"issue":904,"status":"qa","tier":"routine","relays":0}'
out="$(run_tick "$state")"
if grep -qE "fleet-(lane|qa|fix)-904|fleetctl set 904 status=" <<<"$out"; then false; fi
pass "qa status waits for the QA agent to update the record"

state="$(new_state)"
write_record "$state" 905 '{"issue":905,"status":"qa-red","tier":"routine","pr":905,"qa_rounds":1,"relays":0}'
out="$(GH_PR_COMMENTS='the error handling on line 40 swallows the exception' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-fix-905-qa-r1" <<<"$out"
grep -q "DRY: fleetctl set 905 agent=fleet-fix-905-qa-r1 qa_fix_rounds=+1" <<<"$out"
pass "qa-red status dispatches a fix agent with the reviewer's findings instead of waiting for nobody"

state="$(new_state)"
write_record "$state" 906 '{"issue":906,"status":"qa-green","tier":"routine","pr":906,"spec":"docs/x.md","relays":0}'
out="$(GH_PR_FILES='' GH_PR_COMMENTS='' run_tick "$state")"
grep -q "DRY: gh pr merge 906 --squash --auto" <<<"$out"
grep -q "DRY: fleetctl set 906 status=merging" <<<"$out"
pass "qa-green status enables squash auto-merge for a non-user-facing lane"

state="$(new_state)"
reapable="$tmp/reapable-worktree"
mkdir -p "$reapable"
git -C "$reapable" init -q
write_record "$state" 907 "{\"issue\":907,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":907,\"agent\":\"fleet-lane-907\",\"worktree\":\"$reapable\",\"relays\":0}"
# 9070 is a live neighbouring lane: teardown must not touch it, and the
# finished-pane sweep must not either (its lane is still building).
write_record "$state" 9070 "{\"issue\":9070,\"status\":\"building\",\"agent\":\"fleet-lane-9070\",\"relays\":0,\"updated_at\":\"$now_iso\"}"
panes_907='{"result":{"agents":[{"name":"fleet-lane-907","agent_status":"idle","pane_id":"w1:p7"},{"name":"fleet-qa-907-r1","agent_status":"done","pane_id":"w1:p8"},{"name":"fleet-lane-9070","agent_status":"idle","pane_id":"w1:p9"}]}}'
out="$(GH_PR_STATE=MERGED HERDR_AGENTS_JSON="$panes_907" run_tick "$state")"
grep -q "DRY: herdr pane close w1:p7 (fleet-lane-907)" <<<"$out"
grep -q "DRY: herdr pane close w1:p8 (fleet-qa-907-r1)" <<<"$out"
if grep -q "herdr pane close w1:p9" <<<"$out"; then false; fi
grep -q "DRY: git .*worktree remove $reapable" <<<"$out"
grep -q "DRY: fleetctl set 907 status=done" <<<"$out"
pass "merged teardown closes this lane's panes first (and only this lane's), then reaps"

state="$(new_state)"
write_record "$state" 908 '{"issue":908,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","deputy_reason":"needs a decision","deputy_answer":"PARK","relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: needs-ben fleet-daemon issue 908: needs a decision" <<<"$out"
pass "blocked status files the recorded question for Ben"

state="$(new_state)"
write_record "$state" 909 '{"issue":909,"status":"done","tier":"routine","relays":0}'
out="$(run_tick "$state")"
if grep -qE "fleet-(lane|qa)-909|fleetctl set 909 status=" <<<"$out"; then false; fi
grep -q "DRY: fleetctl board" <<<"$out"
pass "done status is skipped and the board is still refreshed"

state="$(new_state)"
done_wt="$tmp/done-worktree"
mkdir -p "$done_wt"
git -C "$done_wt" init -q
write_record "$state" 910 "{\"issue\":910,\"status\":\"done\",\"tier\":\"routine\",\"agent\":\"fleet-lane-910\",\"worktree\":\"$done_wt\",\"relays\":0}"
out="$(HERDR_AGENTS_JSON='{"result":{"agents":[{"name":"fleet-fix-910-r1","agent_status":"idle","pane_id":"w1:pA"}]}}' run_tick "$state")"
grep -q "DRY: herdr pane close w1:pA (fleet-fix-910-r1)" <<<"$out"
grep -q "DRY: git .*worktree remove $done_wt" <<<"$out"
grep -q "DRY: fleetctl set 910 worktree=null" <<<"$out"
pass "a done lane still holding its worktree gets its panes closed and the worktree swept"

state="$(new_state)"
kept_wt="$tmp/kept-worktree"
mkdir -p "$kept_wt"
git -C "$kept_wt" init -q
write_record "$state" 911 "{\"issue\":911,\"status\":\"done\",\"tier\":\"routine\",\"worktree\":\"$kept_wt\",\"teardown_attempts\":5,\"relays\":0}"
out="$(HERDR_AGENTS_JSON='{"result":{"agents":[{"name":"fleet-lane-911","agent_status":"idle","pane_id":"w1:pB"}]}}' run_tick "$state")"
if grep -q "worktree remove $kept_wt" <<<"$out"; then false; fi
# The worktree stays, but the finished agent's window is still reaped.
grep -q "reaped the pane of finished agent fleet-lane-911" <<<"$out"
pass "teardown stops retrying after the attempt cap and leaves the worktree alone"

# --- 20. Unit 3: red checks dispatch a fix agent with the check names in the brief ---

state="$(new_state)"
write_record "$state" 950 '{"issue":950,"status":"ci-red","tier":"routine","pr":950,"relays":0}'
printf '{"ts":"%s","issue":950,"msg":"ci-red: failing checks: lint,test"}\n' "$now_iso" > "$state/log.jsonl"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-fix-950-ci-r1" <<<"$out"
grep -q "lint,test" "$state/briefs/brief-950-fix-ci-r1.md"
grep -q "DRY: fleetctl set 950 agent=fleet-fix-950-ci-r1 ci_fix_rounds=+1" <<<"$out"
pass "a red check dispatches a fix agent with the failing check names written into its brief"

# --- 21. a failed review dispatches a fix agent with the reviewer's findings in the brief ---

state="$(new_state)"
write_record "$state" 951 '{"issue":951,"status":"qa-red","tier":"routine","pr":951,"qa_rounds":1,"relays":0}'
out="$(GH_PR_COMMENTS='missing a null check in the handler' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-fix-951-qa-r1" <<<"$out"
grep -q "missing a null check" "$state/briefs/brief-951-fix-qa-r1.md"
grep -q "DRY: fleetctl set 951 agent=fleet-fix-951-qa-r1 qa_fix_rounds=+1" <<<"$out"
pass "a failed review dispatches a fix agent with the reviewer's findings written into its brief"

# --- 22. a fix agent already at work is left alone, not respawned every tick --------

state="$(new_state)"
write_record "$state" 952 '{"issue":952,"status":"ci-red","tier":"routine","pr":952,"agent":"fleet-fix-952-r1","ci_fix_rounds":1,"relays":0}'
agents_json='{"result":{"agents":[{"name":"fleet-fix-952-r1","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "herdr agent start fleet-fix-952" <<<"$out"; then false; fi
pass "a fix agent still alive and working is left alone, not respawned"

# --- 22b. two different repair causes on one issue never share an agent name -------
# The ci round already ran (its finished agent still holds a pane); the qa
# round must get its own name and spawn, not be blocked by the ci pane.

state="$(new_state)"
write_record "$state" 954 '{"issue":954,"status":"qa-red","tier":"routine","pr":954,"qa_rounds":1,"agent":"fleet-fix-954-ci-r1","ci_fix_rounds":1,"relays":0}'
agents_json='{"result":{"agents":[{"name":"fleet-fix-954-ci-r1","agent_status":"done","pane_id":"w1:p1"}]}}'
out="$(GH_PR_COMMENTS='still failing review' run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: herdr agent start fleet-fix-954-qa-r1" <<<"$out"
grep -q "DRY: fleetctl set 954 agent=fleet-fix-954-qa-r1 qa_fix_rounds=+1" <<<"$out"
pass "a qa fix round is not blocked by the finished ci fix agent's pane"

# --- 22c. a stale pane holding the exact next fix name is closed, not waited on ----

state="$(new_state)"
write_record "$state" 955 '{"issue":955,"status":"ci-red","tier":"routine","pr":955,"relays":0}'
printf '{"ts":"%s","issue":955,"msg":"ci-red: failing checks: lint"}\n' "$now_iso" > "$state/log.jsonl"
agents_json='{"result":{"agents":[{"name":"fleet-fix-955-ci-r1","agent_status":"done","pane_id":"w1:p7"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: herdr pane close w1:p7 (fleet-fix-955-ci-r1)" <<<"$out"
grep -q "DRY: herdr agent start fleet-fix-955-ci-r1" <<<"$out"
pass "a stale finished pane holding the next fix name is closed and the fix respawned"

# --- 23. a third same-cause failure parks with a question for Ben instead of trying again --

state="$(new_state)"
write_record "$state" 953 '{"issue":953,"status":"ci-red","tier":"routine","pr":953,"ci_fix_rounds":2,"relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 953 status=blocked" <<<"$out"
grep -qi "third time" <<<"$out"
if grep -q "herdr agent start fleet-fix" <<<"$out"; then false; fi
pass "a third same-cause failure parks the lane with a question for Ben instead of retrying again"

# --- 24. a dead reviewer, quiet 15 minutes, is respawned once -----------------------

state="$(new_state)"
stale_review_iso="$(date -Iseconds -d '20 minutes ago')"
write_record "$state" 954 "{\"issue\":954,\"status\":\"qa\",\"tier\":\"routine\",\"pr\":954,\"reviewer\":\"fleet-qa-954-r1\",\"qa_rounds\":0,\"relays\":0,\"updated_at\":\"$stale_review_iso\"}"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-954-r1-retry" <<<"$out"
grep -q "DRY: fleetctl set 954 reviewer=fleet-qa-954-r1-retry" <<<"$out"
pass "a dead reviewer, quiet 15 minutes, is respawned once for the same round"

# --- 24b. a reviewer that dies a second time parks instead of respawning again ------

state="$(new_state)"
write_record "$state" 955 "{\"issue\":955,\"status\":\"qa\",\"tier\":\"routine\",\"pr\":955,\"reviewer\":\"fleet-qa-955-r1-retry\",\"qa_rounds\":0,\"relays\":0,\"updated_at\":\"$stale_review_iso\"}"
printf '{"ts":"%s","issue":955,"msg":"reviewer-restart: respawned QA agent for round 1 after the first died"}\n' "$now_iso" > "$state/log.jsonl"
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 955 status=blocked" <<<"$out"
grep -qi "reviewer died twice" <<<"$out"
pass "a reviewer that dies a second time parks the lane instead of respawning again"

# --- 25. the builder field survives a review round, the reviewer gets its own field -

state="$(new_state)"
write_record "$state" 956 '{"issue":956,"status":"pr-open","tier":"routine","pr":956,"branch":"feat/956","agent":"fleet-lane-956","relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 956 status=qa reviewer=fleet-qa-956-r1" <<<"$out"
if grep -q "status=qa agent=" <<<"$out"; then false; fi
pass "starting a review round records the reviewer separately and leaves the builder field alone"

# --- 26. a fresh lane is refused once only the recovery reserve remains, a fix agent still granted --

state="$(new_state)"
printf '{"ts":"%s","issue":958,"msg":"ci-red: failing checks: lint"}\n' "$now_iso" > "$state/log.jsonl"
printf '%s 8\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
write_record "$state" 957 '{"issue":957,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
write_record "$state" 958 '{"issue":958,"status":"ci-red","tier":"routine","pr":958,"relays":0}'
out="$(run_tick "$state" FLEET_SPAWN_BUDGET=10)"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "DRY: herdr agent start fleet-fix-958-ci-r1" <<<"$out"
pass "a fresh lane is refused once only the recovery reserve is left, while a fix agent is still granted"

# --- 27. a lane needing recovery with the whole budget spent parks, reason spawn budget exhausted --

state="$(new_state)"
printf '{"ts":"%s","issue":959,"msg":"ci-red: failing checks: lint"}\n' "$now_iso" > "$state/log.jsonl"
printf '%s 10\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
write_record "$state" 959 '{"issue":959,"status":"ci-red","tier":"routine","pr":959,"relays":0}'
out="$(run_tick "$state" FLEET_SPAWN_BUDGET=10)"
grep -q "DRY: fleetctl set 959 status=blocked" <<<"$out"
grep -qi "spawn budget exhausted" <<<"$out"
pass "a lane needing recovery with the whole budget spent parks at once with reason spawn budget exhausted"

# --- 28. Unit 4: a parked lane with an unchanged reason gets exactly one deputy call, however many ticks pass --

state="$(new_state)"
clear_logs
write_record "$state" 970 '{"issue":970,"status":"blocked","tier":"routine","blocked_reason":"something is stuck","relays":0}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 970: something is stuck" > "$tmp/needs-ben/sent/entry-970.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-970.msg"
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK")"
[ "$(grep -c "claude called" "$SHIM_LOG_DIR/claude.log" 2>/dev/null || echo 0)" -eq 1 ]
grep -q "deputy_reason=something is stuck" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "deputy_answer=PARK" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "deputy_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"

# fleetctl is a stub here and never writes the record back to disk, so the
# next tick's starting point is written by hand -- exactly what a real
# fleetctl would have produced from the "set" call just checked above.
write_record "$state" 970 '{"issue":970,"status":"blocked","tier":"routine","blocked_reason":"something is stuck","relays":0,"deputy_reason":"something is stuck","deputy_answer":"PARK","deputy_attempts":1}'
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK")"
if [ -f "$SHIM_LOG_DIR/claude.log" ]; then false; fi
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK")"
if [ -f "$SHIM_LOG_DIR/claude.log" ]; then false; fi
pass "a parked lane with an unchanged reason gets exactly one deputy call, however many ticks pass"

# --- 29. Unit 4: a changed parked reason permits exactly one more deputy call ------

write_record "$state" 970 '{"issue":970,"status":"blocked","tier":"routine","blocked_reason":"a different problem now","relays":0,"deputy_reason":"something is stuck","deputy_answer":"PARK","deputy_attempts":1}'
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK")"
[ "$(grep -c "claude called" "$SHIM_LOG_DIR/claude.log" 2>/dev/null || echo 0)" -eq 1 ]
grep -q "deputy_reason=a different problem now" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "deputy_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
pass "a changed parked reason is a new situation and permits exactly one more deputy call"

# --- 30. Unit 4: three unparseable deputy answers park the lane with the answer text in the reason --

state="$(new_state)"
write_record "$state" 971 '{"issue":971,"status":"blocked","tier":"routine","blocked_reason":"mystery failure","relays":0}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 971: mystery failure" > "$tmp/needs-ben/sent/entry-971.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-971.msg"

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="not sure what to do")"
grep -q "deputy_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
write_record "$state" 971 '{"issue":971,"status":"blocked","tier":"routine","blocked_reason":"mystery failure","relays":0,"deputy_reason":"mystery failure","deputy_attempts":1}'

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="not sure what to do")"
grep -q "deputy_attempts=2" "$SHIM_LOG_DIR/fleetctl.log"
write_record "$state" 971 '{"issue":971,"status":"blocked","tier":"routine","blocked_reason":"mystery failure","relays":0,"deputy_reason":"mystery failure","deputy_attempts":2}'

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="not sure what to do")"
grep -q "blocked_reason=mystery failure -- the deputy could not produce a clear ruling after 3 tries; last answer: not sure what to do" "$SHIM_LOG_DIR/fleetctl.log"
pass "three unparseable deputy answers park the lane with the model's actual answer in the reason"

# --- 31. Unit 4: a lane parked for hitting the relay cap is never offered RESUME by the deputy --

state="$(new_state)"
write_record "$state" 972 '{"issue":972,"status":"blocked","tier":"routine","blocked_reason":"needs re-slice","relays":2}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 972: needs re-slice" > "$tmp/needs-ben/sent/entry-972.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-972.msg"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK")"
if grep -q "RESUME" "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
if grep -q "MERGE" "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
grep -q "PARK" "$SHIM_LOG_DIR/claude-prompts.log"
pass "a lane parked for hitting the relay cap is offered neither RESUME nor MERGE by the deputy, only PARK"

# --- 32. Unit 4: a dead-lane judgment answer of "I would RESTART" parses as RESTART despite the preface --

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 973 "{\"issue\":973,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="I would RESTART")"
grep -q "judgment ruling: RESTART" "$SHIM_LOG_DIR/fleetctl.log"
pass "a dead-lane judgment answer that prefaces RESTART with other words still parses as RESTART"

# --- 32b. a relayed-out lane gets its successor at once, no timer, no judgment ------

state="$(new_state)"
relay_wt="$tmp/relay-worktree"
mkdir -p "$relay_wt" "$state/briefs"
echo "brief" > "$state/briefs/brief-960-build.md"
write_record "$state" 960 "{\"issue\":960,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-960\",\"worktree\":\"$relay_wt\",\"relays\":1,\"updated_at\":\"$now_iso\"}"
out="$(HERDR_AGENTS_JSON='{"result":{"agents":[{"name":"fleet-lane-960","agent_status":"done","pane_id":"w1:pD"}]}}' run_tick "$state")"
grep -q "DRY: herdr pane close w1:pD (fleet-lane-960)" <<<"$out"
grep -q "DRY: herdr agent start fleet-lane-960" <<<"$out"
grep -q "DRY: fleetctl set 960 status=building agent=fleet-lane-960" <<<"$out"
if grep -q "judgment for lane 960" <<<"$out"; then false; fi
pass "a relayed-out lane respawns its successor immediately with no judgment call"

# --- 32c. a relay already answered with a successor falls back to the dead-lane timer ----

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 961 "{\"issue\":961,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-961\",\"relays\":1,\"updated_at\":\"$stale_iso\"}"
printf '{"ts":"%s","issue":961,"msg":"relay: respawned build agent fleet-lane-961 to continue after relay 1"}\n' "$now_iso" > "$state/log.jsonl"
out="$(run_tick "$state")"
if grep -q "DRY: herdr agent start fleet-lane-961" <<<"$out"; then false; fi
grep -q "judgment for lane 961" <<<"$out"
pass "a relay that already got its successor goes to the dead-lane judgment, not another respawn"

# --- 32d. an approved restart closes a leftover same-name pane instead of aborting -------

state="$(new_state)"
restart_wt="$tmp/restart-worktree"
mkdir -p "$restart_wt" "$state/briefs"
echo "brief" > "$state/briefs/brief-974-build.md"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 974 "{\"issue\":974,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-974\",\"worktree\":\"$restart_wt\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="RESTART" HERDR_AGENTS_JSON='{"result":{"agents":[{"name":"fleet-lane-974","agent_status":"done","pane_id":"w1:pE"}]}}')"
grep -q "pane close w1:pE" "$SHIM_LOG_DIR/herdr.log"
grep -q "restart: respawned build agent fleet-lane-974" "$SHIM_LOG_DIR/fleetctl.log"
pass "an approved restart closes the leftover pane holding the agent's name and respawns"

# --- 33. Unit 4: a dead-lane judgment answer naming both RESTART and PARK does not parse -------

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 974 "{\"issue\":974,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="RESTART or PARK, your call")"
grep -q "judgment ruling: <no answer>" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "judgment_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
pass "a dead-lane judgment answer naming two allowed words does not parse, same as naming none"

# --- 34. Unit 4: three unparseable dead-lane judgment answers park the lane with the answer text in the reason --

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 975 "{\"issue\":975,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="I am thinking about it")"
grep -q "judgment_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
write_record "$state" 975 "{\"issue\":975,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\",\"judgment_attempts\":1}"

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="I am thinking about it")"
grep -q "judgment_attempts=2" "$SHIM_LOG_DIR/fleetctl.log"
write_record "$state" 975 "{\"issue\":975,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\",\"judgment_attempts\":2}"

clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="I am thinking about it")"
grep -q "blocked_reason=dead lane judgment did not get a clear answer after 3 tries; last answer: I am thinking about it" "$SHIM_LOG_DIR/fleetctl.log"
pass "three unparseable dead-lane judgment answers park the lane with the model's actual last answer in the reason"

# --- 35. Unit 5: a failed auto-merge with a behind branch asks GitHub to update it ------

state="$(new_state)"
write_record "$state" 1001 '{"issue":1001,"status":"qa-green","tier":"routine","pr":1001,"spec":"docs/x.md","relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_FILES='' GH_PR_COMMENTS='' GH_MERGE_EXIT=1 GH_MERGE_STDERR='not mergeable: branch out of date' GH_PR_MERGE_STATE=BEHIND)"
grep -q "pr merge 1001 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "pr update-branch 1001" "$SHIM_LOG_DIR/gh.log"
grep -q "set 1001 status=qa-green merge_update_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
pass "a failed auto-merge on a behind branch asks GitHub to update the branch and retries next tick"

# --- 36. Unit 5: two failed update-branch attempts park the lane ------------------------

state="$(new_state)"
write_record "$state" 1002 '{"issue":1002,"status":"qa-green","tier":"routine","pr":1002,"spec":"docs/x.md","relays":0,"merge_update_attempts":2}'
clear_logs
out="$(run_tick_live "$state" GH_PR_FILES='' GH_PR_COMMENTS='' GH_MERGE_EXIT=1 GH_MERGE_STDERR='not mergeable: branch out of date' GH_PR_MERGE_STATE=BEHIND)"
grep -q "set 1002 status=blocked" "$SHIM_LOG_DIR/fleetctl.log"
grep -qi "two update attempts" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "pr update-branch 1002" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "two failed update-branch attempts park the lane instead of trying forever"

# --- 37. Unit 5: a real conflict (found on the merge re-check) dispatches a fix agent ----

state="$(new_state)"
stale_iso="$(date -Iseconds -d '50 minutes ago')"
write_record "$state" 1003 "{\"issue\":1003,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":1003,\"branch\":\"fix/1003\",\"worktree\":\"/tmp/wt-1003\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=OPEN GH_PR_MERGE_STATE=DIRTY run_tick "$state")"
grep -q "DRY: herdr agent start fleet-fix-1003-merge-r1" <<<"$out"
grep -qi "bring this branch up to date with main, resolve the conflicts, push" "$state/briefs/brief-1003-fix-merge-r1.md"
grep -q "DRY: fleetctl set 1003 agent=fleet-fix-1003-merge-r1 merge_fix_rounds=+1" <<<"$out"
pass "a real merge conflict dispatches a fix agent with the rebase-and-push brief, counted as a fix round"

# --- 38. Unit 5: an auto-merge refused for any other reason parks with the command's own error text --

state="$(new_state)"
write_record "$state" 1004 '{"issue":1004,"status":"qa-green","tier":"routine","pr":1004,"spec":"docs/x.md","relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_FILES='' GH_PR_COMMENTS='' GH_MERGE_EXIT=1 GH_MERGE_STDERR='auto-merge is not enabled for this repository' GH_PR_MERGE_STATE=BLOCKED)"
grep -q "set 1004 status=blocked" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "auto-merge is not enabled for this repository" "$SHIM_LOG_DIR/fleetctl.log"
pass "an auto-merge refused for a reason other than behind or conflicts parks with the command's own error text"

# --- 39. Unit 5: a lane stuck merging past 45 minutes re-checks and routes -------------

state="$(new_state)"
stale_iso="$(date -Iseconds -d '50 minutes ago')"
write_record "$state" 1005 "{\"issue\":1005,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":1005,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=OPEN GH_PR_MERGE_STATE=BEHIND run_tick "$state")"
grep -q "DRY: gh pr update-branch 1005" <<<"$out"
grep -q "DRY: fleetctl set 1005 status=qa-green merge_update_attempts=1" <<<"$out"
pass "a lane stuck merging past 45 minutes re-checks the merge state and routes the fix"

state="$(new_state)"
stale_iso="$(date -Iseconds -d '50 minutes ago')"
write_record "$state" 1006 "{\"issue\":1006,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":1006,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=OPEN GH_PR_MERGE_STATE=BLOCKED run_tick "$state")"
grep -q "DRY: fleetctl set 1006 status=blocked" <<<"$out"
grep -qi "still merging after 45 minutes" <<<"$out"
grep -q "BLOCKED" <<<"$out"
pass "a lane stuck merging past 45 minutes with no mechanical fix parks with the state as the reason"

# --- 40. Unit 5: a lane still merging inside the 45-minute window is left alone --------

state="$(new_state)"
recent_iso="$(date -Iseconds -d '10 minutes ago')"
write_record "$state" 1007 "{\"issue\":1007,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":1007,\"relays\":0,\"updated_at\":\"$recent_iso\"}"
out="$(GH_PR_STATE=OPEN GH_PR_MERGE_STATE=BEHIND run_tick "$state")"
if grep -q "pr update-branch" <<<"$out"; then false; fi
if grep -q "fleetctl set 1007 status=" <<<"$out"; then false; fi
pass "a lane still merging inside the 45-minute window is left alone"

# --- 41. Unit 5: checks pending past 90 minutes trigger exactly one re-run request -----

state="$(new_state)"
stale_iso="$(date -Iseconds -d '95 minutes ago')"
write_record "$state" 1008 "{\"issue\":1008,\"status\":\"pr-open\",\"tier\":\"routine\",\"pr\":1008,\"relays\":0,\"branch\":\"feat/1008\",\"updated_at\":\"$stale_iso\"}"
out="$(GH_CHECKS='[{"name":"build","bucket":"pending"}]' GH_RUN_ID=4242 run_tick "$state")"
grep -q "DRY: gh run rerun 4242" <<<"$out"
grep -q "DRY: fleetctl set 1008 checks_rerun_requested=1" <<<"$out"
pass "checks pending past 90 minutes trigger exactly one re-run request"

# --- 42. Unit 5: a second timeout after the re-run parks with "checks never finished" ---

state="$(new_state)"
stale_iso="$(date -Iseconds -d '95 minutes ago')"
write_record "$state" 1009 "{\"issue\":1009,\"status\":\"pr-open\",\"tier\":\"routine\",\"pr\":1009,\"relays\":0,\"branch\":\"feat/1009\",\"updated_at\":\"$stale_iso\",\"checks_rerun_requested\":1}"
out="$(GH_CHECKS='[{"name":"build","bucket":"pending"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 1009 status=blocked" <<<"$out"
grep -q "checks never finished" <<<"$out"
if grep -q "gh run rerun" <<<"$out"; then false; fi
pass "checks still pending after the re-run request parks the lane as checks never finished"

# --- 43. Unit 6: a merged lane closes its issue and moves its board entry, exactly once each --

state="$(new_state)"
write_record "$state" 2001 '{"issue":2001,"status":"merging","tier":"routine","pr":2001,"relays":0}'
clear_logs
project_json='{"items":[{"id":"item_2001","status":"In Progress","content":{"type":"Issue","number":2001}}]}'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED GH_PROJECT_JSON="$project_json")"
[ "$(grep -c "issue close 2001 --comment" "$SHIM_LOG_DIR/gh.log")" = "1" ]
[ "$(grep -c "project item-edit --id item_2001 --project-id proj_1 --field-id field_status --single-select-option-id opt_done" "$SHIM_LOG_DIR/gh.log")" = "1" ]
grep -q "set 2001 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "a merged lane closes its GitHub issue and moves its board entry to Done, one action each, before being marked done"

# --- 44. Unit 6: a failed close keeps the lane un-done and retries -----------------

state="$(new_state)"
write_record "$state" 2002 '{"issue":2002,"status":"merging","tier":"routine","pr":2002,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED GH_ISSUE_CLOSE_EXIT=1 GH_ISSUE_CLOSE_STDERR='something went wrong')"
if grep -q "set 2002 status=done" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "set 2002 closeout_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
grep -qi "attempt 1 of 3" "$SHIM_LOG_DIR/fleetctl.log"
pass "a failed close-out keeps the lane out of done and retries next tick"

# --- 45. Unit 6: the third failed attempt marks the lane done anyway with a note ---

state="$(new_state)"
write_record "$state" 2003 '{"issue":2003,"status":"merging","tier":"routine","pr":2003,"relays":0,"closeout_attempts":2}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED GH_ISSUE_CLOSE_EXIT=1 GH_ISSUE_CLOSE_STDERR='something went wrong')"
grep -q "set 2003 closeout_attempts=3" "$SHIM_LOG_DIR/fleetctl.log"
grep -qi "still open on GitHub after 3 attempts" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2003 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "the third failed close-out attempt marks the lane done anyway with a still-open-on-GitHub note"

# --- 46. Unit 6: an already-closed issue and an already-Done board entry are quiet no-ops --

state="$(new_state)"
write_record "$state" 2004 '{"issue":2004,"status":"merging","tier":"routine","pr":2004,"relays":0}'
clear_logs
project_json='{"items":[{"id":"item_2004","status":"Done","content":{"type":"Issue","number":2004}}]}'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED GH_ISSUE_STATE=CLOSED GH_PROJECT_JSON="$project_json")"
if grep -q "issue close 2004" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "item-edit" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -qi "already closed" "$SHIM_LOG_DIR/fleetctl.log"
grep -qi "already in Done" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2004 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "an issue already closed and a board entry already in Done proceed quietly, one log line each, no double action"

# --- 47. Unit 6: a parked lane's pull request is never closed ---------------------

state="$(new_state)"
write_record "$state" 2005 '{"issue":2005,"status":"blocked","tier":"routine","pr":2005,"branch":"fix/2005-thing","blocked_reason":"needs a decision","relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=OPEN)"
if grep -q "issue close 2005" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "a parked lane's pull request and issue are left alone, not closed by the daemon"

# --- 48. Unit 7 bullet 1: a broken judge command is a fleet alarm, not a silent choice ---

# 48a. Intake: a new issue's tiering fails to run at all -- must not be silently
# defaulted to security, and must not be added half-triaged.
state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":991,"title":"New task","body":"x"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_EXIT=1 >/dev/null
grep -q "ALARM: the judge command could not run at all" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "add 991" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a broken judge command at intake raises a fleet alarm and leaves the issue untiered, not defaulted to security"

# 48b. Dead-lane judgment call: the command itself fails to run.
state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 992 "{\"issue\":992,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
clear_logs
run_tick_live "$state" CLAUDE_EXIT=1 >/dev/null
grep -q "ALARM: the judge command could not run at all" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "set 992" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a broken judge command on a dead lane raises the alarm and leaves the lane exactly as it is"

# 48c. Deputy call: the command itself fails to run.
state="$(new_state)"
write_record "$state" 993 '{"issue":993,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 993: stuck on a decision" > "$tmp/needs-ben/sent/entry-993.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-993.msg"
clear_logs
run_tick_live "$state" CLAUDE_EXIT=1 >/dev/null
grep -q "ALARM: the judge command could not run at all" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "log 993 deputy could not ask a ruling this tick" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "set 993" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a broken judge command during a deputy call raises the alarm and leaves the lane parked"

# --- 49. Unit 7 bullet 3: a reply from Ben always does something ------------------

# 49a. "resume" re-queues the lane.
state="$(new_state)"
write_record "$state" 970 '{"issue":970,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
echo "resume issue 970" > "$tmp/needs-ben/replies/reply-970.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 970 status=queued" <<<"$out"
grep -q "Ben replied 'resume': lane is back in the queue" <<<"$out"
pass "a reply starting with resume re-queues the lane"

# 49b. "merge" enables auto-merge, subject to the existing gates.
state="$(new_state)"
write_record "$state" 971 '{"issue":971,"status":"blocked","tier":"routine","pr":971,"blocked_reason":"needs a decision","relays":0}'
echo "merge issue 971" > "$tmp/needs-ben/replies/reply-971.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: gh pr merge 971 --squash --auto" <<<"$out"
grep -q "Ben replied 'merge': auto-merge enabled on PR #971" <<<"$out"
pass "a reply starting with merge enables auto-merge on the pull request"

# 49c. "merge" is still refused past the live-path hard floor, even from Ben.
state="$(new_state)"
write_record "$state" 972 '{"issue":972,"status":"blocked","tier":"routine","pr":972,"blocked_reason":"code-complete, unverified: needs live-path proof","relays":0}'
echo "merge issue 972" > "$tmp/needs-ben/replies/reply-972.txt"
clear_logs
out="$(run_tick "$state")"
if grep -q "gh pr merge" <<<"$out"; then false; fi
grep -q "merge refused, still parked" <<<"$out"
pass "a reply saying merge is refused when the live-path check has not been proven, even from Ben"

# 49d. Anything else stamps the record so the board shows it needs reading.
state="$(new_state)"
write_record "$state" 973 '{"issue":973,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
echo "not sure yet, ask again tomorrow issue 973" > "$tmp/needs-ben/replies/reply-973.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "Ben replied, needs reading" <<<"$out"
pass "a reply that is not resume or merge still stamps the record so the board shows it needs reading"

# 49e (near miss, from the review): a reply's clock time is never read as naming
# an unrelated issue number.
state="$(new_state)"
write_record "$state" 30 '{"issue":30,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
echo "call at 10:30, will decide later" > "$tmp/needs-ben/replies/reply-clock.txt"
clear_logs
out="$(run_tick "$state")"
if grep -qE "Ben replied|status=queued|pr merge" <<<"$out"; then false; fi
pass "a reply's clock time is never mistaken for naming issue 30"

# 49f. A reply older than the current question is never acted on (59 stale reply
# files on disk, 2026-08-25 review: the oldest one used to fire on the NEXT park
# of that issue, whatever the new question was).
state="$(new_state)"
write_record "$state" 974 "{\"issue\":974,\"status\":\"blocked\",\"tier\":\"routine\",\"blocked_reason\":\"needs a decision\",\"question\":\"needs a decision\",\"questionAskedAt\":\"$(date -Iseconds)\",\"relays\":0}"
echo "resume issue 974" > "$tmp/needs-ben/replies/reply-974.txt"
touch -d '2 hours ago' "$tmp/needs-ben/replies/reply-974.txt"
clear_logs
out="$(run_tick "$state")"
if grep -q "Ben replied" <<<"$out"; then false; fi
pass "a reply from before the current question was asked is ignored"

# 49g. A reply sent after the question was asked still works.
state="$(new_state)"
write_record "$state" 976 "{\"issue\":976,\"status\":\"blocked\",\"tier\":\"routine\",\"blocked_reason\":\"needs a decision\",\"question\":\"needs a decision\",\"questionAskedAt\":\"$(date -Iseconds -d '1 hour ago')\",\"relays\":0}"
echo "resume issue 976" > "$tmp/needs-ben/replies/reply-976.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "Ben replied 'resume': lane is back in the queue" <<<"$out"
pass "a reply from after the question was asked is still acted on"

# --- 50. Unit 7 bullet 4: a worktree failure retries once, then parks -------------

state="$(new_state)"
write_record "$state" 975 '{"issue":975,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
run_tick_live "$state" GIT_WORKTREE_ADD_EXIT=1 GIT_WORKTREE_ADD_STDERR='fatal: already exists' >/dev/null
grep -q "worktree creation failed (attempt 1 of 2): fatal: already exists; will retry next tick" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "status=blocked" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a first worktree failure logs and retries, without parking the lane"

clear_logs
write_record "$state" 975 '{"issue":975,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md","worktree_attempts":1}'
run_tick_live "$state" GIT_WORKTREE_ADD_EXIT=1 GIT_WORKTREE_ADD_STDERR='fatal: already exists' >/dev/null
grep -q "status=blocked" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "blocked_reason=could not create the worktree: fatal: already exists" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "worktree creation failed twice in a row; parked with the git error as the reason" "$SHIM_LOG_DIR/fleetctl.log"
pass "a second worktree failure in a row parks the lane with the git error as the reason"

# --- 51. Unit 7 bullet 5: no second agent on a busy lane, but a near-miss name is fine ---

state="$(new_state)"
write_record "$state" 980 '{"issue":980,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-980","agent_status":"working","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "not spawning: an agent for issue #980 is still working" <<<"$out"
if grep -q "worktree add" <<<"$out"; then false; fi
pass "a lane is not dispatched a second time while its own agent is still working"

state="$(new_state)"
write_record "$state" 981 '{"issue":981,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-9810","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: git .*worktree add" <<<"$out"
grep -q "DRY: herdr agent start fleet-lane-981" <<<"$out"
pass "an agent for a different, similarly-numbered issue does not block dispatch"

# --- 52. Unit 7 bullet 6: a brief gives a real, resolvable command, not bare fleetctl ---

state="$(new_state)"
write_record "$state" 990 '{"issue":990,"status":"pr-open","tier":"routine","pr":990,"branch":"feat/990","relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state")"
brief="$state/briefs/brief-990-qa-r1.md"
[ -f "$brief" ]
grep -q "node .*/fleetctl.mjs set 990 status=qa-green" "$brief"
if grep -qE '(^|[^/[:alnum:]_.])fleetctl set 990' "$brief"; then false; fi
pass "a QA brief tells the reviewer the full resolvable command, not bare fleetctl"

# --- 53. Unit 7 bullet 7: idle backoff checks GitHub every tenth tick once settled ---

state="$(new_state)"
write_record "$state" 994 '{"issue":994,"status":"done","tier":"routine","relays":0}'
clear_logs
run_tick_live "$state" >/dev/null # tick 1: the run just went idle
[ "$(grep -c "api graphql" "$SHIM_LOG_DIR/gh.log")" = "1" ]
grep -q "run complete: every lane is done or parked" "$SHIM_LOG_DIR/fleetctl.log"

clear_logs
for _ in 2 3 4 5 6 7 8 9 10; do
  run_tick_live "$state" >/dev/null
done
if grep -q "api graphql" "$SHIM_LOG_DIR/gh.log" 2>/dev/null; then false; fi

clear_logs
run_tick_live "$state" >/dev/null # tick 11: the tenth idle tick since the last check
[ "$(grep -c "api graphql" "$SHIM_LOG_DIR/gh.log")" = "1" ]
pass "once every lane is done or parked, GitHub is checked on the first idle tick and then every tenth tick, not every tick"

# --- 54. Unit 7 bullet 9: a fleet-level memory warning fires even with nothing to spawn --

state="$(new_state)"
write_record "$state" 995 '{"issue":995,"status":"done","tier":"routine","relays":0}'
low_mem="$tmp/meminfo-low"
printf 'MemTotal:       8192000 kB\nMemAvailable:   1024000 kB\n' > "$low_mem"
clear_logs
out="$(run_tick "$state" FLEET_MEMINFO="$low_mem")"
grep -q "DRY: fleetctl log fleet WARNING: free memory is below the" <<<"$out"
pass "low memory is logged as a fleet-level warning even on a tick where nothing tries to spawn"

# --- 55. Unit 7 bullet 10: the nightly spawn counter persists across ticks --------

state="$(new_state)"
write_record "$state" 997 '{"issue":997,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick "$state" >/dev/null
read -r _ count1 < "$state/.spawn-count"
[ "$count1" = "1" ]
rm -f "$state/tasks/997.json"
write_record "$state" 998 '{"issue":998,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick "$state" >/dev/null
read -r _ count2 < "$state/.spawn-count"
[ "$count2" = "2" ]
pass "the nightly spawn counter is a small persisted file that accumulates across ticks"

# --- 56. Unit 7 bullet 11: the terminal manager being unreachable is one fleet alarm ---

state="$(new_state)"
write_record "$state" 999 '{"issue":999,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick "$state" HERDR_AGENT_LIST_EXIT=1)"
[ "$(grep -c "ALARM: the terminal manager" <<<"$out")" = "1" ]
if grep -qE "worktree add|herdr agent start" <<<"$out"; then false; fi
pass "the terminal manager being unreachable raises one fleet alarm and blocks every spawn attempt, not a failure storm per lane"

# --- 57. mid-edit guard: edits in the tooling's own checkout skip the whole tick ---

state="$(new_state)"
write_record "$state" 3001 '{"issue":3001,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(GIT_STATUS_OUT=' M tick.sh' run_tick "$state")"
grep -q "fleet code has uncommitted edits, tick skipped (quiet guard" <<<"$out"
if grep -qE "worktree add|herdr agent start" <<<"$out"; then false; fi
pass "uncommitted edits to a tracked file in the tooling checkout skip the tick with one quiet fleet log line"

out="$(GIT_STATUS_OUT='?? notes.txt' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-3001" <<<"$out"
if grep -q "uncommitted edits" <<<"$out"; then false; fi
pass "an untracked stray file in the tooling checkout does not stop the tick"

# --- 58. a deputy MERGE is refused when a user-facing PR has no live-path proof ---

state="$(new_state)"
clear_logs
write_record "$state" 3010 '{"issue":3010,"status":"blocked","tier":"routine","pr":310,"spec":"docs/x.md","blocked_reason":"stuck on a decision","relays":0}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 3010: stuck on a decision" > "$tmp/needs-ben/sent/entry-3010.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-3010.msg"
run_tick_live "$state" CLAUDE_ANSWER="MERGE" GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS="looks fine to me" >/dev/null
if grep -q "pr merge 310" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -q "DEPUTY MERGE refused: user-facing PR #310 has no live-path proof" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "deputy_answer=PARK" "$SHIM_LOG_DIR/fleetctl.log"
pass "a deputy MERGE on a user-facing PR without live-path proof is refused and remembered as PARK"

# --- 59. a deputy MERGE whose auto-merge fails routes the failure like a normal merge ---

state="$(new_state)"
clear_logs
write_record "$state" 3011 '{"issue":3011,"status":"blocked","tier":"routine","pr":311,"spec":"docs/x.md","blocked_reason":"stuck on a decision","relays":0}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 3011: stuck on a decision" > "$tmp/needs-ben/sent/entry-3011.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-3011.msg"
run_tick_live "$state" CLAUDE_ANSWER="MERGE" GH_PR_FILES='' GH_PR_COMMENTS='' GH_MERGE_EXIT=1 GH_MERGE_STDERR='not mergeable: branch out of date' GH_PR_MERGE_STATE=BEHIND >/dev/null
grep -q "pr merge 311 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "pr update-branch 311" "$SHIM_LOG_DIR/gh.log"
grep -q "set 3011 status=qa-green merge_update_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "set 3011 status=merging" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a deputy MERGE whose auto-merge fails is routed like a normal merge failure, not marked merging"

# --- 60. Ben's merge reply is refused when a user-facing PR has no live-path proof ---

state="$(new_state)"
write_record "$state" 3020 '{"issue":3020,"status":"blocked","tier":"routine","pr":320,"spec":"docs/x.md","blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3020" > "$tmp/needs-ben/replies/reply-3020.txt"
clear_logs
out="$(GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS='' run_tick "$state")"
if grep -q "gh pr merge" <<<"$out"; then false; fi
grep -q "merge refused, still parked" <<<"$out"
pass "Ben's merge reply on a user-facing PR without live-path proof is refused, whatever the parked reason says"

# --- 61. Ben's merge reply whose auto-merge fails routes the failure like a normal merge ---

state="$(new_state)"
write_record "$state" 3021 '{"issue":3021,"status":"blocked","tier":"routine","pr":321,"spec":"docs/x.md","blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3021" > "$tmp/needs-ben/replies/reply-3021.txt"
clear_logs
run_tick_live "$state" GH_PR_FILES='' GH_PR_COMMENTS='' GH_MERGE_EXIT=1 GH_MERGE_STDERR='not mergeable: branch out of date' GH_PR_MERGE_STATE=BEHIND >/dev/null
grep -q "pr merge 321 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "pr update-branch 321" "$SHIM_LOG_DIR/gh.log"
grep -q "set 3021 status=qa-green merge_update_attempts=1" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "set 3021 status=merging" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
[ -f "$tmp/needs-ben/replies/reply-3021.txt.handled" ]
pass "Ben's merge reply whose auto-merge fails is routed like a normal merge failure, and the reply is marked handled"

# --- 62. Ben's merge reply on a starved tick is left unread and retried next tick ---

state="$(new_state)"
write_record "$state" 3030 '{"issue":3030,"status":"pr-open","tier":"routine","pr":330,"relays":0}'
write_record "$state" 3031 '{"issue":3031,"status":"blocked","tier":"routine","pr":331,"blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3031" > "$tmp/needs-ben/replies/reply-3031.txt"
clear_logs
run_tick_live "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' >/dev/null
if grep -q "pr merge 331" "$SHIM_LOG_DIR/gh.log"; then false; fi
[ -f "$tmp/needs-ben/replies/reply-3031.txt" ]
[ ! -f "$tmp/needs-ben/replies/reply-3031.txt.handled" ]
pass "when GitHub is refusing to answer, Ben's merge reply is left unread so the gates are really checked next tick"
rm -f "$tmp/needs-ben/replies/reply-3031.txt"

# --- 63. the PR head commit comes from the REST door first ---

state="$(new_state)"
write_record "$state" 3040 '{"issue":3040,"status":"pr-open","tier":"routine","pr":340,"branch":"feat/3040","relays":0}'
clear_logs
out="$(GH_API_PR_SHA='cafe1234' GH_API_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-3040-r1" <<<"$out"
if grep -q -- "--json headRefOid" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "pr checks" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "the PR head commit comes from the REST door first; the old door is untouched when REST answers"

# --- 64. PR merged-state and issue state come from the REST door first ---

state="$(new_state)"
write_record "$state" 3041 '{"issue":3041,"status":"merging","tier":"routine","pr":341,"relays":0}'
clear_logs
project_json='{"items":[{"id":"item_3041","status":"Done","content":{"type":"Issue","number":3041}}]}'
run_tick_live "$state" GH_API_PR_STATE=MERGED GH_API_ISSUE_STATE=CLOSED GH_PR_STATE=OPEN GH_ISSUE_STATE=OPEN GH_PROJECT_JSON="$project_json" >/dev/null
grep -q "set 3041 status=done" "$SHIM_LOG_DIR/fleetctl.log"
grep -qi "already closed" "$SHIM_LOG_DIR/fleetctl.log"
# The old doors say OPEN on both counts; only the REST answers explain the
# result, and neither old door nor a close was touched.
if grep -q "pr view 341" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "issue view" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "issue close 3041" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "whether a PR merged and whether its issue is closed come from the REST door first, old doors untouched"

# --- 65. the mergeable state of a stuck merge comes from the REST door first ---

state="$(new_state)"
stale_iso="$(date -Iseconds -d '50 minutes ago')"
write_record "$state" 3042 "{\"issue\":3042,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":342,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
clear_logs
out="$(GH_API_PR_STATE=OPEN GH_API_PR_MERGE_STATE=BEHIND run_tick "$state")"
grep -q "DRY: gh pr update-branch 342" <<<"$out"
grep -q "DRY: fleetctl set 3042 status=qa-green merge_update_attempts=1" <<<"$out"
if grep -q "pr view 342" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "the mergeable state of a stuck merge comes from the REST door first, old door untouched"

# --- 66. a RESTART ruling blocked by the spawn budget is remembered, not re-asked every tick ---

state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 3050 "{\"issue\":3050,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
printf '%s 10\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
clear_logs
run_tick_live "$state" CLAUDE_ANSWER="RESTART" FLEET_SPAWN_BUDGET=10 >/dev/null
[ "$(grep -c "claude called" "$SHIM_LOG_DIR/claude.log")" -eq 1 ]
grep -q "set 3050 judgment_answer=RESTART judgment_hold=spawn budget exhausted" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "restart approved but spawn budget exhausted" "$SHIM_LOG_DIR/fleetctl.log"

# The stub fleetctl never writes records back, so the next tick's starting
# point is written by hand -- what the "set" just checked would have produced.
write_record "$state" 3050 "{\"issue\":3050,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\",\"judgment_answer\":\"RESTART\",\"judgment_hold\":\"spawn budget exhausted\"}"
clear_logs
run_tick_live "$state" CLAUDE_ANSWER="RESTART" FLEET_SPAWN_BUDGET=10 >/dev/null
if [ -f "$SHIM_LOG_DIR/claude.log" ]; then false; fi
pass "a held RESTART ruling is remembered; the judge is not re-asked while the budget is still spent"

printf '%s 0\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
clear_logs
run_tick_live "$state" CLAUDE_ANSWER="RESTART" FLEET_SPAWN_BUDGET=10 >/dev/null
grep -q "set 3050 judgment_answer= judgment_hold=" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "the block that held the approved restart" "$SHIM_LOG_DIR/fleetctl.log"
[ "$(grep -c "claude called" "$SHIM_LOG_DIR/claude.log")" -eq 1 ]
pass "once the budget recovers the hold is cleared and the judge is asked exactly once more"

# --- 67. a rate-limited checks re-run request starves the tick and spends no attempt ---

state="$(new_state)"
stale_iso="$(date -Iseconds -d '95 minutes ago')"
write_record "$state" 3060 "{\"issue\":3060,\"status\":\"pr-open\",\"tier\":\"routine\",\"pr\":360,\"relays\":0,\"branch\":\"feat/3060\",\"updated_at\":\"$stale_iso\"}"
out="$(GH_CHECKS='[{"name":"build","bucket":"pending"}]' GH_RUN_ID= GH_RUN_LIST_STDERR='API rate limit exceeded' run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer" <<<"$out"
if grep -q "checks_rerun_requested=1" <<<"$out"; then false; fi
if grep -q "run rerun" <<<"$out"; then false; fi
pass "a rate-limited re-run request reads as GitHub refusing to answer and does not spend the one re-run attempt"

# --- 68. a rate-limited intake read starves the tick instead of passing as an empty board ---

state="$(new_state)"
clear_logs
run_tick_live "$state" GH_PROJECT_JSON= GH_PROJECT_LIST_STDERR='API rate limit exceeded' >/dev/null
grep -q "ALARM: GitHub is refusing to answer" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "^add " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a rate-limited board read at intake reads as GitHub refusing to answer, not as an empty board"

# --- 69. a reply file with spaces in its name is still found and acted on ---

state="$(new_state)"
write_record "$state" 3070 '{"issue":3070,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
echo "resume issue 3070" > "$tmp/needs-ben/replies/reply from phone 3070.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 3070 status=queued" <<<"$out"
grep -q "Ben replied 'resume'" <<<"$out"
pass "a reply file with spaces in its name is still found and acted on"
rm -f "$tmp/needs-ben/replies/reply from phone 3070.txt"

# --- 70. intake is opt-in: only issues labeled for a run are taken ---

# Two Ready task issues, one labeled fleet-run and one not. The labeled one
# is taken; the unlabeled one is passed over in silence -- no record, no log
# line, nothing. Its turn comes when someone labels it.
state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":4001,"title":"Wanted work","body":"x"}},{"status":"Ready","labels":["task"],"content":{"type":"Issue","number":4002,"title":"Not this run","body":"x"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "add 4001" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 4001 title=Wanted work" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "4002" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
# The daemon also writes a board snapshot for the viewer: every Ready /
# In progress issue, labeled or not, with its in-run mark.
jq -e 'map(.number) == [4001, 4002] and .[0].inRun == true and .[1].inRun == false' "$state/board-issues.json" >/dev/null
pass "intake takes a fleet-run labeled issue and passes an unlabeled one in silence"

# The board read keeps its spacing: with a fresh snapshot on disk and the
# spacing set high, the next tick does not read the board at all -- a newly
# labeled issue waits, and the snapshot stays as it was. With the spacing
# off (a stale snapshot), the issue is taken and the snapshot refreshed.
project_json='{"items":[{"status":"Ready","labels":["fleet-run"],"content":{"type":"Issue","number":4005,"title":"Late arrival","body":"x"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" FLEET_BOARD_CHECK_SECONDS=600 CLAUDE_ANSWER="ROUTINE" >/dev/null
[ ! -f "$state/tasks/4005.json" ]
jq -e 'map(.number) == [4001, 4002]' "$state/board-issues.json" >/dev/null
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "add 4005" "$SHIM_LOG_DIR/fleetctl.log"
jq -e 'map(.number) == [4005]' "$state/board-issues.json" >/dev/null
pass "board reads keep their spacing; a stale snapshot is refreshed"

# 70b. The label name is a knob like the others, overridable by environment.
state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","night-shift"],"content":{"type":"Issue","number":4003,"title":"Custom label","body":"x"}},{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":4004,"title":"Default label","body":"x"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" FLEET_RUN_LABEL=night-shift CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "add 4003" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "add 4004" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "the run label is overridable by environment, and the default name stops counting then"

# --- 71. the board entry moves to In progress the moment a lane is picked up ---

# 71a. A real (non-dry) dispatch spawns the agent and moves the issue's board
# entry to In progress, exactly once.
state="$(new_state)"
write_record "$state" 4100 '{"issue":4100,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
project_json='{"items":[{"id":"item_4100","status":"Ready","content":{"type":"Issue","number":4100}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" >/dev/null
grep -q "agent start fleet-lane-4100" "$SHIM_LOG_DIR/herdr.log"
grep -q "set 4100 status=building" "$SHIM_LOG_DIR/fleetctl.log"
[ "$(grep -c "project item-edit --id item_4100 --project-id proj_1 --field-id field_status --single-select-option-id opt_inprogress" "$SHIM_LOG_DIR/gh.log")" = "1" ]
pass "picking up a lane moves its board entry to In progress, exactly once"

# 71b. A board move that fails outright is one logged warning; the spawn is
# already done and the lane proceeds -- the build matters more than the board.
state="$(new_state)"
write_record "$state" 4101 '{"issue":4101,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
project_json='{"items":[{"id":"item_4101","status":"Ready","content":{"type":"Issue","number":4101}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ITEM_EDIT_EXIT=1 GH_ITEM_EDIT_STDERR='something broke' >/dev/null
grep -q "agent start fleet-lane-4101" "$SHIM_LOG_DIR/herdr.log"
grep -q "set 4101 status=building" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "the build goes on regardless" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "board_move_pending=1" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a failed board move on pickup is one warning and does not stop the spawn"

# 71c. A rate-limited board move is noted on the record and retried next
# tick; the retry clears the note once the move lands.
state="$(new_state)"
write_record "$state" 4102 '{"issue":4102,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
project_json='{"items":[{"id":"item_4102","status":"Ready","content":{"type":"Issue","number":4102}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ITEM_EDIT_EXIT=1 GH_ITEM_EDIT_STDERR='API rate limit exceeded' >/dev/null
grep -q "set 4102 status=building" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 4102 board_move_pending=1" "$SHIM_LOG_DIR/fleetctl.log"

# The stub fleetctl never writes records back, so the next tick's starting
# point is written by hand -- what the "set" just checked would have produced.
write_record "$state" 4102 "{\"issue\":4102,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4102\",\"relays\":0,\"board_move_pending\":1,\"updated_at\":\"$now_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4102","pane_id":"w1:p9"}]}}'
clear_logs
run_tick_live "$state" GH_PROJECT_JSON="$project_json" HERDR_AGENTS_JSON="$agents_json" >/dev/null
[ "$(grep -c "project item-edit --id item_4102 --project-id proj_1 --field-id field_status --single-select-option-id opt_inprogress" "$SHIM_LOG_DIR/gh.log")" = "1" ]
grep -q "set 4102 board_move_pending=$" "$SHIM_LOG_DIR/fleetctl.log"
pass "a rate-limited board move is remembered on the record and lands on the next tick's retry"

# --- 72. the real brief tells a fresh lane to write its spec before any code ---

state="$(new_state)"
write_record "$state" 4200 '{"issue":4200,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick "$state" FLEET_BRIEF_TEMPLATE="$tool_root/brief-template.md" >/dev/null
brief="$state/briefs/brief-4200-build.md"
[ -f "$brief" ]
grep -q "Plan first" "$brief"
grep -q "docs/specs/4200.md" "$brief"
grep -qi "first line is exactly \`SPEC\`" "$brief"
if grep -q '\${ISSUE}' "$brief"; then false; fi
pass "a fresh lane's brief carries the plan-first rule with the spec path resolved to its issue"

# The brief tells the agent how to write its lane record. That command must
# be the fleetctl the daemon resolved, never the pre-move hard-coded path
# (a live agent briefed with the dead path can neither report, park, nor
# relay -- seen live 2026-08-24 on the first real dispatch).
if grep -q "scripts/fleet" "$state/briefs"/brief-*-build.md; then false; fi
grep -q "fleetctl set" "$state/briefs"/brief-*-build.md
pass "the brief's record commands use the resolved fleetctl, not the pre-move path"

# --- 33. a lane that parks itself as too big re-slices automatically, any wording --

state="$(new_state)"
write_record "$state" 985 '{"issue":985,"status":"blocked","tier":"routine","relays":1,"blocked_reason":"This issue is bigger than fits in one lane session even with the relay already used. Needs splitting.","spec":"https://github.com/motioneso/fake/issues/985"}'
out="$(run_tick "$state")"
grep -q "re-slice draft for lane 985" <<<"$out"
grep -q "DRY: fleetctl set 985 reslice_failures=1" <<<"$out"
if grep -q "set 985 reslice_attempted=1" <<<"$out"; then false; fi
grep -q "could not re-slice this parked lane automatically (failure 1 of 3)" <<<"$out"
grep -q "deputy for lane 985" <<<"$out"
pass "a self-parked 'too big' lane tries the automatic re-slice in the agent's own words"

# --- 33b. the parked-lane re-slice is attempted once, never a model-call loop -------

state="$(new_state)"
write_record "$state" 986 '{"issue":986,"status":"blocked","tier":"routine","relays":1,"blocked_reason":"needs splitting into two lanes","reslice_attempted":1,"spec":"https://github.com/motioneso/fake/issues/986"}'
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
grep -q "deputy for lane 986" <<<"$out"
pass "a parked lane whose re-slice already failed goes to the deputy, not another draft"

# --- 33c. the deputy is never offered MERGE for a lane with no pull request ---------

state="$(new_state)"
write_record "$state" 987 '{"issue":987,"status":"blocked","tier":"routine","relays":0,"blocked_reason":"mystery failure with no pull request"}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="MERGE")"
if grep -q "MERGE (enable auto-merge" "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
grep -q "RESUME (put the lane back in the queue) or PARK" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q "DEPUTY answer did not parse" "$SHIM_LOG_DIR/fleetctl.log"
pass "a PR-less parked lane offers the deputy only RESUME or PARK, and a stray MERGE is counted, not dropped"

# --- 34. a merged part revisits its parent: judge says DONE, parent closes ---------

state="$(new_state)"
write_record "$state" 2100 '{"issue":2100,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2101","resliced_to":2101,"spec":"https://github.com/motioneso/fake/issues/2100"}'
write_record "$state" 2101 '{"issue":2101,"status":"merging","tier":"routine","pr":91,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE")"
grep -q "issue #2100 was split into parts" "$SHIM_LOG_DIR/claude-prompts.log"
[ "$(grep -c "issue close 2100" "$SHIM_LOG_DIR/gh.log")" = "1" ]
grep -q "issue close 2100 --repo motioneso/fake --comment All parts of this issue are finished and merged" "$SHIM_LOG_DIR/gh.log"
grep -q "set 2100 status=done blocked_reason=" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2101 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "a merged part whose parent has no work left closes the parent issue and marks its lane done"

# --- 34b. a merged part revisits its parent: judge drafts the next part ------------

state="$(new_state)"
write_record "$state" 2110 '{"issue":2110,"status":"blocked","tier":"sensitive","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2111","resliced_to":2111,"spec":"https://github.com/motioneso/fake/issues/2110"}'
write_record "$state" 2111 '{"issue":2111,"status":"merging","tier":"sensitive","pr":92,"relays":0}'
clear_logs
next_part=$'Fake feature part 2 of #2110\nThe first part delivered the read path. This part covers the write path.'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="$next_part" GH_ISSUE_CREATE_URL="https://github.com/motioneso/fake/issues/2112")"
grep -q "issue create --repo motioneso/fake --title Fake feature part 2 of #2110" "$SHIM_LOG_DIR/gh.log"
grep -q "Re-sliced by the fleet daemon from #2110" "$SHIM_LOG_DIR/gh.log"
grep -q "add 2112 spec=https://github.com/motioneso/fake/issues/2112 tier=sensitive" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2112 title=Fake feature part 2 of #2110" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2110 blocked_reason=re-sliced automatically: remaining work is issue #2112 resliced_to=2112" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "issue close 2110" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "set 2110 status=done" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a merged part whose parent has work left cuts the next part, queues it, and repoints the parent"

# --- 34c. a merged lane with no parent skips the revisit entirely ------------------

state="$(new_state)"
write_record "$state" 2120 '{"issue":2120,"status":"merging","tier":"routine","pr":93,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE")"
if grep -q "split into parts" "$SHIM_LOG_DIR/claude-prompts.log" 2>/dev/null; then false; fi
if grep -q "issue create" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -q "set 2120 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "a merged lane that was never split out of a parent closes out normally with no judge call"

# --- 34d. an unparseable revisit answer leaves the parent exactly as it was --------

state="$(new_state)"
write_record "$state" 2130 '{"issue":2130,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2131","resliced_to":2131,"spec":"https://github.com/motioneso/fake/issues/2130"}'
write_record "$state" 2131 '{"issue":2131,"status":"merging","tier":"routine","pr":94,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="")"
if grep -q "issue close 2130" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "issue create" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "set 2130 " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "parent-revisit draft for issue #2130 came back empty" "$SHIM_LOG_DIR/fleetctl.log"
pass "an empty revisit answer logs a warning and touches nothing on the parent"


# --- 60. 2026-08-25 stall fixes: replies, leftovers, local branches, idle corpses ---

# 60a. Ben's real reply "resume, proceed with split" must count as resume:
# the comma alone parked lane 1955 for three hours.
state="$(new_state)"
write_record "$state" 974 '{"issue":974,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
echo "issue 974: resume, proceed with split" > "$tmp/needs-ben/replies/reply-974.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 974 status=queued" <<<"$out"
grep -q "Ben replied 'resume': lane is back in the queue" <<<"$out"
pass "a resume with trailing punctuation and extra words still counts as resume"

# 60b. An idle leftover agent on a queued lane is closed, not treated as live
# forever (lane 1955's requeue was blocked for hours by the old idle window).
state="$(new_state)"
write_record "$state" 982 '{"issue":982,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-982","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "closed the leftover agent window fleet-lane-982" <<<"$out"
grep -q "DRY: herdr pane close w1:p1" <<<"$out"
if grep -q "herdr agent start fleet-lane-982" <<<"$out"; then false; fi
pass "an idle leftover agent on a queued lane is closed instead of blocking dispatch forever"

# 60c. A branch that exists only locally is adopted with a plain worktree add,
# never re-created with -b (which can only fail against an existing name).
state="$(new_state)"
write_record "$state" 984 '{"issue":984,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state" GIT_SHOWREF_EXIT=0)"
grep -q "worktree add .*fleet-lane-984 fleet/lane-984" <<<"$out"
if grep -q "worktree add -b" <<<"$out"; then false; fi
pass "a branch that exists only locally is adopted, never re-created with -b"

# 60d. A session that sits open but idle on a silent building lane is a corpse:
# close it and send the relay successor (lane 1951 froze 11 hours this way).
state="$(new_state)"
old_iso="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
write_record "$state" 985 "{\"issue\":985,\"status\":\"building\",\"agent\":\"fleet-lane-985\",\"tier\":\"routine\",\"relays\":1,\"worktree\":\"$fake_repo\",\"updated_at\":\"$old_iso\"}"
mkdir -p "$state/briefs"
echo brief > "$state/briefs/brief-985-build.md"
agents_json='{"result":{"agents":[{"name":"fleet-lane-985","agent_status":"idle","pane_id":"w1:p1"}]}}'
clear_logs
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "open but idle" <<<"$out"
grep -q "relay: respawned build agent fleet-lane-985" <<<"$out"
pass "an idle session on a silent building lane is closed and the relay successor is sent"

# 60e. A working agent is never treated as a corpse, however old the record.
state="$(new_state)"
write_record "$state" 986 "{\"issue\":986,\"status\":\"building\",\"agent\":\"fleet-lane-986\",\"tier\":\"routine\",\"relays\":1,\"updated_at\":\"$old_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-986","agent_status":"working","pane_id":"w1:p1"}]}}'
clear_logs
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "open but idle" <<<"$out"; then false; fi
if grep -q "relay: respawned" <<<"$out"; then false; fi
pass "a working agent is never treated as a corpse, however silent the lane record"

# 60f. A recently-active lane keeps its idle agent: idle alone is not death.
state="$(new_state)"
fresh_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_record "$state" 987 "{\"issue\":987,\"status\":\"building\",\"agent\":\"fleet-lane-987\",\"tier\":\"routine\",\"relays\":1,\"updated_at\":\"$fresh_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-987","agent_status":"idle","pane_id":"w1:p1"}]}}'
clear_logs
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "open but idle" <<<"$out"; then false; fi
pass "an idle agent on a recently-active lane is left alone"

# --- 61. finished work has its panes reaped -----------------------------------------

# 61a. An idle agent on a done lane is swept
state="$(new_state)"
write_record "$state" 990 '{"issue":990,"status":"done","tier":"routine"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-990","agent_status":"idle","pane_id":"w1:p9"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "reaped the pane of finished agent fleet-lane-990" <<<"$out"
grep -q "DRY: herdr pane close w1:p9" <<<"$out"
pass "an idle agent on a done lane has its pane reaped"

# 61b. A stopped agent on a parked lane is swept too
state="$(new_state)"
write_record "$state" 991 '{"issue":991,"status":"blocked","tier":"routine","blocked_reason":"re-sliced automatically: remaining work is issue #999","relays":2}'
agents_json='{"result":{"agents":[{"name":"fleet-qa-991","agent_status":"done","pane_id":"w1:pA"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "reaped the pane of finished agent fleet-qa-991" <<<"$out"
pass "a stopped agent on a parked lane has its pane reaped"

# 61c. A working agent is never swept, even on a done lane
state="$(new_state)"
write_record "$state" 990 '{"issue":990,"status":"done","tier":"routine"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-990","agent_status":"working","pane_id":"w1:p9"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "reaped the pane" <<<"$out"; then false; fi
pass "a working agent is never swept, even when its lane record says done"

# 61d. A fleet-named agent with no lane record at all is swept
state="$(new_state)"
agents_json='{"result":{"agents":[{"name":"fleet-fix-999","agent_status":"idle","pane_id":"w1:pB"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "reaped the pane of finished agent fleet-fix-999" <<<"$out"
pass "a fleet-named agent whose lane record is gone has its pane reaped"

# 61e. A leftover whose status reads "done" no longer blocks dispatch (lane 1951,
# 2026-08-25: the closer skipped done agents, and the name stayed taken forever).
state="$(new_state)"
write_record "$state" 992 '{"issue":992,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
agents_json='{"result":{"agents":[{"name":"fleet-lane-992","agent_status":"done","pane_id":"w1:p2"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "closed the leftover agent window fleet-lane-992" <<<"$out"
grep -q "DRY: herdr pane close w1:p2" <<<"$out"
pass "a leftover reporting done is closed at dispatch instead of holding the name forever"

# 61f. A failed agent start closes the window it just opened (lane 1951's loop
# left one empty agent-less pane per minute; the sweep cannot see nameless panes).
state="$(new_state)"
write_record "$state" 993 '{"issue":993,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick_live "$state" HERDR_AGENT_START_EXIT=1 >/dev/null 2>&1 || true
grep -q "log 993 dispatch failed: could not spawn build agent fleet-lane-993" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "pane close w1:p9" "$SHIM_LOG_DIR/herdr.log"
pass "a failed agent start closes the empty window it opened instead of leaking it"

# --- 62. Step 4: a deputy PARK on a transient cause is re-asked once the cause clears --
# Parked on "spawn budget exhausted" with the deputy's PARK stamped: while the
# budget is still spent nothing is re-asked, but once the budget recovers the
# stamps are cleared and the deputy gets exactly one fresh call.
state="$(new_state)"
printf '%s 10\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
write_record "$state" 975 '{"issue":975,"status":"blocked","tier":"routine","blocked_reason":"spawn budget exhausted","relays":0,"deputy_reason":"spawn budget exhausted","deputy_answer":"PARK","deputy_attempts":1}'
printf '{"deputyEnabled": true}\n' > "$state/settings.json"
echo "issue 975: spawn budget exhausted" > "$tmp/needs-ben/sent/entry-975.msg"
touch -d '30 minutes ago' "$tmp/needs-ben/sent/entry-975.msg"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK" FLEET_SPAWN_BUDGET=10)"
if [ -f "$SHIM_LOG_DIR/claude.log" ]; then false; fi
pass "a stamped PARK on spawn-budget-exhausted stays quiet while the budget is still spent"

printf '%s 0\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
clear_logs
out="$(run_tick_live "$state" CLAUDE_ANSWER="PARK" FLEET_SPAWN_BUDGET=10)"
[ "$(grep -c "claude called" "$SHIM_LOG_DIR/claude.log" 2>/dev/null || echo 0)" -eq 1 ]
grep -q "set 975 deputy_reason= deputy_answer= deputy_attempts=0" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "has cleared; asking the deputy once more" "$SHIM_LOG_DIR/fleetctl.log"
pass "once the budget recovers the deputy stamps clear and the deputy is asked exactly once more"

# --- 63. Step 5: a transient re-slice failure does not kill auto-splitting forever --
# Failure 1 happened (counted above in test 33). A later tick where the judge
# and gh answer must still succeed and only then stamp the attempt as used.
state="$(new_state)"
write_record "$state" 988 '{"issue":988,"status":"blocked","tier":"routine","relays":1,"blocked_reason":"needs splitting into two lanes","reslice_failures":1,"spec":"https://github.com/motioneso/fake/issues/988"}'
clear_logs
draft=$'Fake feature remainder of #988\nThe first session delivered half; this covers the rest.'
out="$(run_tick_live "$state" CLAUDE_ANSWER="$draft" GH_ISSUE_CREATE_URL="https://github.com/motioneso/fake/issues/989")"
grep -q "issue create --repo motioneso/fake --title Fake feature remainder of #988" "$SHIM_LOG_DIR/gh.log"
grep -q "set 988 reslice_attempted=1" "$SHIM_LOG_DIR/fleetctl.log"
pass "a re-slice that failed once succeeds on a later try and only then uses up the attempt"

# 63b. Three failures give up: no more drafts, straight to the deputy.
state="$(new_state)"
write_record "$state" 989 '{"issue":989,"status":"blocked","tier":"routine","relays":1,"blocked_reason":"needs splitting into two lanes","reslice_failures":3,"spec":"https://github.com/motioneso/fake/issues/989"}'
out="$(run_tick "$state")"
if grep -q "re-slice draft" <<<"$out"; then false; fi
grep -q "deputy for lane 989" <<<"$out"
pass "three failed re-slice tries give up for good and hand the lane to the deputy"

# --- 64. Step 6: a lane wedged in a red repair state raises the stillness alarm ----
state="$(new_state)"
stale_hour_iso="$(date -Iseconds -d '90 minutes ago')"
printf '{"ts":"%s","issue":135,"msg":"ci-red: failing checks: lint"}\n' "$stale_hour_iso" > "$state/log.jsonl"
write_record "$state" 135 "{\"issue\":135,\"status\":\"ci-red\",\"tier\":\"routine\",\"pr\":135,\"relays\":0,\"updated_at\":\"$stale_hour_iso\"}"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: fleetctl log fleet ALARM: stillness" <<<"$out"
pass "a lane wedged in ci-red for a full hour with no news raises the stillness alarm"

# --- 65. Step 7: a waived lane that keeps relaying leaves a soft alarm every 6th relay --
state="$(new_state)"
write_record "$state" 3300 "{\"issue\":3300,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-3300\",\"relays\":6,\"relay_cap_waived\":1,\"spec\":\"https://github.com/motioneso/fake/issues/3300\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
[ "$(grep -c "ALARM: this lane has relayed 6 times" <<<"$out")" -eq 1 ]
pass "a waived lane at 6 relays leaves exactly one soft alarm"

# 65b. relays=7 is not a multiple of 6: quiet.
state="$(new_state)"
write_record "$state" 3301 "{\"issue\":3301,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-3301\",\"relays\":7,\"relay_cap_waived\":1,\"spec\":\"https://github.com/motioneso/fake/issues/3301\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
if grep -q "ALARM: this lane has relayed" <<<"$out"; then false; fi
pass "a waived lane at 7 relays does not re-alarm"

# 65c. the alarm is de-duped across ticks: an identical last log line stays silent.
state="$(new_state)"
printf '{"ts":"%s","issue":3302,"msg":"ALARM: this lane has relayed 6 times under the standing resume rule; it keeps handing off without finishing - worth a human look"}\n' "$now_iso" > "$state/log.jsonl"
write_record "$state" 3302 "{\"issue\":3302,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-3302\",\"relays\":6,\"relay_cap_waived\":1,\"spec\":\"https://github.com/motioneso/fake/issues/3302\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
if grep -q "DRY: fleetctl log 3302 ALARM: this lane has relayed" <<<"$out"; then false; fi
pass "an already-logged relay alarm is not repeated while it stays the last line"

echo "fleet tick tests passed"
