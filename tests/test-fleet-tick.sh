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
# REAP_VERDICT lets a test force KEEP; the default answers REAPABLE.
echo "${REAP_VERDICT:-REAPABLE}"
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
    # A spawn test can make agents appear only AFTER a start has been
    # attempted (the count file below is written by every stubbed start):
    # that is what a slow-to-report-ready agent looks like from outside.
    # HERDR_AGENT_APPEARS_AFTER_LISTS, if set, keeps the agent hidden for that
    # many listings first: a pane takes its agent name a moment after the start
    # gives up, so the fleet has to ask more than once to see it.
    lc="$SHIM_LOG_DIR/herdr-agent-list-count.log"
    lcn="$(cat "$lc" 2>/dev/null || echo 0)"
    echo "$((lcn + 1))" > "$lc"
    if [ -n "${HERDR_AGENTS_JSON_AFTER_START:-}" ] && [ -s "$SHIM_LOG_DIR/herdr-agent-start-count.log" ] \
       && [ "$lcn" -ge "${HERDR_AGENT_APPEARS_AFTER_LISTS:-0}" ]; then
      printf '%s\n' "$HERDR_AGENTS_JSON_AFTER_START"
      exit "${HERDR_AGENT_LIST_EXIT:-0}"
    fi
    printf '%s\n' "${HERDR_AGENTS_JSON:-$no_agents}"
    exit "${HERDR_AGENT_LIST_EXIT:-0}"
    ;;
  "pane list")  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1"}]}}' ;;
  "agent start")
    # HERDR_AGENT_START_FAILS, if set, fails the first N starts (counted in a
    # file so retries inside one tick are seen; a big N means "always fails").
    # HERDR_AGENT_START_STDERR is what a failing start says on stderr.
    if [ -n "${HERDR_AGENT_START_FAILS:-}" ]; then
      cf="$SHIM_LOG_DIR/herdr-agent-start-count.log"
      n="$(cat "$cf" 2>/dev/null || echo 0)"
      n=$((n + 1))
      echo "$n" > "$cf"
      if [ "$n" -le "$HERDR_AGENT_START_FAILS" ]; then
        echo "${HERDR_AGENT_START_STDERR:-simulated start failure}" >&2
        exit 1
      fi
      exit 0
    fi
    if [ "${HERDR_AGENT_START_EXIT:-0}" != "0" ] && [ -n "${HERDR_AGENT_START_STDERR:-}" ]; then
      echo "$HERDR_AGENT_START_STDERR" >&2
    fi
    exit "${HERDR_AGENT_START_EXIT:-0}"
    ;;
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
  "issue list")
    # The parent-revisit path asks for open issues that already mention the
    # parent, so the judge can reuse one instead of drafting a duplicate.
    [ -n "${GH_ISSUE_LIST_STDERR:-}" ] && echo "${GH_ISSUE_LIST_STDERR}" >&2
    printf '%s\n' "${GH_ISSUE_LIST_JSON:-[]}"
    exit "${GH_ISSUE_LIST_EXIT:-0}"
    ;;
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
      *"--json commits"*)    printf '%s\n' "${GH_PR_LAST_COMMIT_ISO:-}" ;;
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
    # Two different GraphQL calls land here. The starve alarm's self-check
    # asks GitHub's GraphQL endpoint for its own budget count (authoritative;
    # the free meter under-reports it). Unset means that call fails, and the
    # stderr knob makes it fail the way a real exhausted pool does.
    case "$*" in
      *rateLimit*)
        [ -n "${GH_GQL_RATELIMIT_STDERR:-}" ] && echo "${GH_GQL_RATELIMIT_STDERR}" >&2
        if [ -z "${GH_GQL_RATELIMIT_JSON:-}" ]; then exit 1; fi
        printf '%s\n' "$GH_GQL_RATELIMIT_JSON"
        exit 0
        ;;
    esac
    # The slim board read. Answers in the GraphQL page shape, built from the
    # same item-list style fixture (GH_PROJECT_JSON) the old call used, so
    # no fixture changes. Same stderr / empty-answer knobs as before.
    [ -n "${GH_PROJECT_LIST_STDERR:-}" ] && echo "${GH_PROJECT_LIST_STDERR}" >&2
    board="${GH_PROJECT_JSON-$no_items}"
    if [ -z "$board" ]; then exit 1; fi # "GitHub gave nothing back"
    jq -c '{data:{viewer:{projectV2:{items:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[.items[]? | {id:(.id // null), fieldValueByName:{name:(.status // null)}, content:{__typename:(.content.type // "Issue"), number:.content.number, title:.content.title, body:(.content.body // ""), state:(.content.state // null), labels:{nodes:[(.labels // [])[] | {name:.}]}, repository:{nameWithOwner:(.content.repository // "motioneso/fake")}}}]}}}}}' <<<"$board"
    ;;
  "api rate_limit")
    # GitHub's free budget meter (counts against neither pool). Unset means
    # the probe itself fails and the alarm falls back to its older wording.
    if [ -z "${GH_RATE_LIMIT_JSON:-}" ]; then exit 1; fi
    printf '%s\n' "$GH_RATE_LIMIT_JSON"
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
    # "worktree list" answers which branch is checked out where; a test sets
    # GIT_WORKTREE_LIST_OUT to porcelain text. It must not be affected by the
    # add-failure knob below.
    if [ "\$1" = "-C" ]; then wt_action="\${4:-}"; else wt_action="\${2:-}"; fi
    if [ "\$wt_action" = "list" ]; then
      printf '%s' "\${GIT_WORKTREE_LIST_OUT:-}"
      exit 0
    fi
    if [ -n "\${GIT_WORKTREE_ADD_EXIT:-}" ] && [ "\${GIT_WORKTREE_ADD_EXIT:-0}" != "0" ]; then
      printf '%s\n' "\${GIT_WORKTREE_ADD_STDERR:-simulated worktree failure}" >&2
      exit "\$GIT_WORKTREE_ADD_EXIT"
    fi
    exit 0
    ;;
  # The dropped-checks nudge commits and pushes; recorded, never executed,
  # so a test can assert the exact commit message and that no force is used.
  commit)    echo "\$*" >> "\$SHIM_LOG_DIR/git.log"; exit 0 ;;
  push)      echo "\$*" >> "\$SHIM_LOG_DIR/git.log"; exit 0 ;;
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
  # The written-plan gate applies to every queued lane at every hour, so a
  # test lane needs a plan in the fake repo unless it is testing the gate
  # itself (see write_record_without_plan).
  mkdir -p "$fake_repo/docs/specs"
  printf 'plan for %s\n' "$2" > "$fake_repo/docs/specs/$2.md"
}

write_record_without_plan() { # <state-dir> <issue> <json>
  write_record "$@"
  rm -f "$fake_repo/docs/specs/$2.md"
}

clear_logs() {
  rm -f "$SHIM_LOG_DIR"/*.log
}

run_tick() { # <state-dir> [extra env KEY=VAL...]; dry-run unless FLEET_DRY_RUN passed
  local state="$1"
  shift
  PATH="$tmp/bin:$PATH" \
    JARV1S_FLEET_STATE="$state" \
    JARV1S_REPO="$fake_repo" \
    FLEET_BRIEF_TEMPLATE="$template" \
    NEEDS_BEN_DIR="$tmp/needs-ben" \
    FLEET_MEMINFO="$meminfo_ok" \
    FLEET_BOARD_CHECK_SECONDS=0 \
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

# --- 8i. a queued issue with no written plan stays queued, at any hour -------------

state="$(new_state)"
write_record_without_plan "$state" 500 '{"issue":500,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/500"}'
out="$(run_tick "$state")"
grep -q "written-plan rule: not dispatching" <<<"$out"
if grep -q "herdr agent start fleet-lane-500" <<<"$out"; then false; fi
pass "an issue with no written plan is not dispatched"

# --- 8i-2. the old day/night switch is gone: setting it changes nothing -------------
# The old rule only applied between two hours, and start==end turned it off. Both
# settings are dead now, so passing them must not open the gate.

state="$(new_state)"
write_record_without_plan "$state" 502 '{"issue":502,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/502"}'
out="$(run_tick "$state" FLEET_OVERNIGHT_START_HOUR=0 FLEET_OVERNIGHT_END_HOUR=0)"
grep -q "written-plan rule: not dispatching" <<<"$out"
if grep -q "herdr agent start fleet-lane-502" <<<"$out"; then false; fi
pass "the retired day/night hours no longer switch the written-plan gate off"

# --- 8j. a SPEC comment on the issue counts as the plan -----------------------------

state="$(new_state)"
write_record_without_plan "$state" 500 '{"issue":500,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/500"}'
out="$(run_tick "$state" GH_SPEC_COMMENT_COUNT=1)"
grep -q "DRY: herdr agent start fleet-lane-500" <<<"$out"
pass "an issue comment starting with SPEC counts as the plan and dispatch goes ahead"

# --- 8k. a spec file in the repo counts as the plan ---------------------------------

state="$(new_state)"
write_record "$state" 501 '{"issue":501,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/501"}'
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-501" <<<"$out"
pass "a spec file in the repo counts as the plan and dispatch goes ahead"

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

# --- 9b. a closed issue is never adopted, whatever its card says --------------
# Issue 1909 was closed on 2026-08-25 with its card left in "In progress".
# Two days later intake took it as fresh work and the fleet spent 33 minutes
# trying to start a spec-writer for a finished job.

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"In progress","labels":["task","fleet-run"],"content":{"type":"Issue","number":209,"title":"Already done","body":"finished days ago","state":"CLOSED"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
if grep -q "add 209 " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
[ ! -f "$state/tasks/209.json" ]
pass "a closed issue is never adopted, whatever column its card sits in"

# ...and its card is moved out of the way, so the board stops claiming the
# work is live and the card is never seen by this loop again.
state="$(new_state)"
clear_logs
project_json='{"items":[{"id":"item_213","status":"In progress","labels":["task","fleet-run"],"content":{"type":"Issue","number":213,"title":"Done already","body":"x","state":"CLOSED"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
[ "$(grep -c "project item-edit --id item_213 --project-id proj_1 --field-id field_status --single-select-option-id opt_done" "$SHIM_LOG_DIR/gh.log")" = "1" ]
pass "a closed issue's card is moved to Done so the board stops showing it as live"

# A backlog of them is worked a few per board read, so one tick never spends
# minutes moving cards.
state="$(new_state)"
clear_logs
items=""
for i in 220 221 222 223 224 225 226; do
  items="$items{\"id\":\"item_$i\",\"status\":\"Ready\",\"labels\":[\"task\",\"fleet-run\"],\"content\":{\"type\":\"Issue\",\"number\":$i,\"title\":\"t\",\"body\":\"b\",\"state\":\"CLOSED\"}},"
done
project_json="{\"items\":[${items%,}]}"
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
[ "$(grep -c "project item-edit" "$SHIM_LOG_DIR/gh.log")" = "5" ]
pass "a backlog of closed cards is moved a few per board read, not all at once"

# An open issue alongside it is still adopted, so the check is not a blanket stop.
state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":210,"title":"Done one","body":"x","state":"CLOSED"}},{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":211,"title":"Live one","body":"y","state":"OPEN"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
if grep -q "add 210 " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "add 211 " "$SHIM_LOG_DIR/fleetctl.log"
pass "a closed card next to an open one stops only the closed one"

# An issue whose state the board did not report is adopted as before, so a
# missing field never silently stops the fleet taking work.
state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":212,"title":"No state field","body":"z"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "add 212 " "$SHIM_LOG_DIR/fleetctl.log"
pass "an issue with no reported state is still adopted"

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

# --- 10b. The ls-remote fallback only adopts a whole-token branch match -------------
# gh knows no branch, so intake falls back to listing remote branches. A
# branch for issue 1951 contains the digits 195; issue 195 must skip it and
# pick its own branch when one exists.

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":195,"title":"Own branch","body":"x"}}]}'
lsremote_out=$'abc123\trefs/heads/fleet/lane-1951\ndef456\trefs/heads/fleet/lane-195'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ISSUE_BRANCHES="" GIT_LSREMOTE_OUT="$lsremote_out" GH_PR_LIST="" CLAUDE_ANSWER="ROUTINE" >/dev/null
grep -q "set 195 branch=fleet/lane-195" "$SHIM_LOG_DIR/fleetctl.log"
pass "the remote-branch fallback picks the whole-token match, not a longer number containing it"

# --- 10c. A near-miss-only listing adopts nothing -----------------------------------

state="$(new_state)"
clear_logs
project_json='{"items":[{"status":"Ready","labels":["task","fleet-run"],"content":{"type":"Issue","number":195,"title":"No branch","body":"x"}}]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_ISSUE_BRANCHES="" GIT_LSREMOTE_OUT=$'abc123\trefs/heads/fleet/lane-1951' GH_PR_LIST="" CLAUDE_ANSWER="ROUTINE" >/dev/null
if grep -q "set 195 branch=" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "log 195 intake: queued issue #195 fresh" "$SHIM_LOG_DIR/fleetctl.log"
pass "a remote listing with only a near-miss branch queues the issue fresh"

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

# --- 18c. a NEW question on a lane that already asked one replaces the phone entry --
# Live lane 1951 (2026-08-25): stamping the record without replacing the phone entry
# left the mismatch in place, so the clock refreshed EVERY tick and every reply Ben
# sent aged out as stale. The old entry must be retired, a fresh one sent, and the
# clock stamped exactly once.

out="$(run_tick "$state" <<<"" )"
: # same state dir: entry-801.msg says "needs a schema decision"
write_record "$state" 801 '{"issue":801,"status":"blocked","tier":"routine","blocked_reason":"a wholly new question","deputy_reason":"a wholly new question","deputy_answer":"PARK","relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: mv $tmp/needs-ben/sent/entry-801.msg" <<<"$out"
grep -q "DRY: needs-ben fleet-daemon issue 801: a wholly new question" <<<"$out"
grep -q "DRY: fleetctl set 801 question=a wholly new question questionAskedAt=" <<<"$out"
[ "$(grep -c "set 801 question=" <<<"$out")" = 1 ]
pass "a re-parked lane retires the stale phone entry, sends the new question, stamps once"

# --- 18d. once the fresh entry is on file, the clock stops moving -------------------
# Simulates the tick after the real (non-dry) mv+send: the entry now carries the new
# question. Nothing may re-fire, or replies keep aging out forever.

echo "issue 801: a wholly new question" > "$tmp/needs-ben/sent/entry-801.msg"
out="$(run_tick "$state")"
if grep -q "set 801 question=" <<<"$out"; then false; fi
if grep -q "DRY: needs-ben" <<<"$out"; then false; fi
pass "a replaced entry that matches the current question is left alone"

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
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state")"
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
write_record "$state" 907 "{\"issue\":907,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":907,\"agent\":\"fleet-lane-907\",\"branch\":\"fleet/lane-907\",\"worktree\":\"$reapable\",\"relays\":0}"
# 9070 is a live neighbouring lane: teardown must not touch it, and the
# finished-pane sweep must not either (its lane is still building).
write_record "$state" 9070 "{\"issue\":9070,\"status\":\"building\",\"agent\":\"fleet-lane-9070\",\"relays\":0,\"updated_at\":\"$now_iso\"}"
panes_907='{"result":{"agents":[{"name":"fleet-lane-907","agent_status":"idle","pane_id":"w1:p7"},{"name":"fleet-qa-907-r1","agent_status":"done","pane_id":"w1:p8"},{"name":"fleet-lane-9070","agent_status":"idle","pane_id":"w1:p9"},{"name":"fleet-rescue-907-r1","agent_status":"done","pane_id":"w1:pR"}]}}'
out="$(GH_PR_STATE=MERGED GIT_SHOWREF_EXIT=0 HERDR_AGENTS_JSON="$panes_907" run_tick "$state")"
grep -q "DRY: herdr pane close w1:p7 (fleet-lane-907)" <<<"$out"
grep -q "DRY: herdr pane close w1:p8 (fleet-qa-907-r1)" <<<"$out"
grep -q "DRY: herdr pane close w1:pR (fleet-rescue-907-r1)" <<<"$out"
if grep -q "herdr pane close w1:p9" <<<"$out"; then false; fi
grep -q "DRY: git .*worktree remove $reapable" <<<"$out"
grep -q "DRY: git .*branch -D fleet/lane-907" <<<"$out"
grep -q "DRY: fleetctl set 907 status=done --pr-merged" <<<"$out"
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
if grep -q "branch -D" <<<"$out"; then false; fi # no recorded branch -> nothing to delete
grep -q "DRY: fleetctl set 910 worktree=null" <<<"$out"
pass "a done lane still holding its worktree gets its panes closed and the worktree swept"

state="$(new_state)"
kept_wt="$tmp/kept-worktree"
mkdir -p "$kept_wt"
git -C "$kept_wt" init -q
write_record "$state" 911 "{\"issue\":911,\"status\":\"done\",\"tier\":\"routine\",\"worktree\":\"$kept_wt\",\"teardown_attempts\":5,\"relays\":0}"
out="$(HERDR_AGENTS_JSON='{"result":{"agents":[{"name":"fleet-lane-911","agent_status":"idle","pane_id":"w1:pB"}]}}' run_tick "$state")"
if grep -q "worktree remove $kept_wt" <<<"$out"; then false; fi
grep -q "DRY: fleetctl log 911 ALARM: teardown given up after 5 tries" <<<"$out"
# The worktree stays, but the finished agent's window is still reaped.
grep -q "reaped the pane of finished agent fleet-lane-911" <<<"$out"
pass "teardown stops retrying after the attempt cap and leaves the worktree alone (with an alarm)"

# A merged lane whose worktree still holds leftover files (a relay handoff
# note, uncommitted edits) used to jam teardown forever: the reap check said
# KEEP every tick until the give-up alarm. Now teardown salvages the
# leftovers into the state dir and retries before burning an attempt.
state="$(new_state)"
dirty_wt="$tmp/dirty-worktree"
mkdir -p "$dirty_wt"
git -C "$dirty_wt" init -q
printf 'original\n' > "$dirty_wt/app.txt"
git -C "$dirty_wt" add app.txt
git -C "$dirty_wt" -c user.email=t@test -c user.name=t commit -q -m "seed"
printf 'edited after merge\n' > "$dirty_wt/app.txt" # modified tracked file
mkdir -p "$dirty_wt/docs"
printf 'handoff notes\n' > "$dirty_wt/docs/notes.md" # untracked file
write_record "$state" 912 "{\"issue\":912,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":912,\"worktree\":\"$dirty_wt\",\"relays\":0}"
out="$(GH_PR_STATE=MERGED REAP_VERDICT=KEEP run_tick "$state")"
grep -q "DRY: save the worktree's uncommitted diff to .*/salvage/912-uncommitted-.*\.patch" <<<"$out"
grep -q "DRY: move 1 untracked file(s) from $dirty_wt into .*/salvage/912-untracked/" <<<"$out"
grep -q "DRY: fleetctl log 912 teardown: saved leftover uncommitted work to the salvage folder before cleanup (2 files)" <<<"$out"
grep -q "DRY: git .*worktree remove $dirty_wt" <<<"$out"
grep -q "DRY: fleetctl set 912 status=done --pr-merged" <<<"$out"
if grep -q "teardown_attempts" <<<"$out"; then false; fi # salvage happened before an attempt was burned
pass "merged teardown salvages leftover files to the state dir and then reaps"

# KEEP with a genuinely clean tree means the blocker is something else
# (a live process, say): nothing to salvage, so the keep/retry behavior is
# unchanged and no salvage lines appear.
state="$(new_state)"
clean_kept_wt="$tmp/clean-kept-worktree"
mkdir -p "$clean_kept_wt"
git -C "$clean_kept_wt" init -q
write_record "$state" 913 "{\"issue\":913,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":913,\"worktree\":\"$clean_kept_wt\",\"relays\":0}"
out="$(GH_PR_STATE=MERGED REAP_VERDICT=KEEP run_tick "$state")"
if grep -qi "salvage" <<<"$out"; then false; fi
if grep -q "worktree remove $clean_kept_wt" <<<"$out"; then false; fi
grep -q "DRY: fleetctl set 913 teardown_attempts=1" <<<"$out"
pass "reap KEEP on a clean tree still just retries next tick, with no salvage"

# A merged lane whose worktree still hosts an orphaned leftover process (lane
# 1975's abandoned pnpm dev server, reparented to pid 1) used to jam teardown:
# gate 3 of the reap check said KEEP every tick until the give-up alarm. Now
# teardown politely asks such orphans to stop before the reap check runs.
# FLEET_PROC_ROOT points tick.sh at a fake /proc built here: pid 4242 is an
# orphan (parent pid 1) working inside the worktree, pid 4243 works there too
# but still has a live parent and must be left alone.
state="$(new_state)"
orphan_wt="$tmp/orphan-worktree"
mkdir -p "$orphan_wt"
git -C "$orphan_wt" init -q
fake_proc="$tmp/fake-proc"
mkdir -p "$fake_proc/4242" "$fake_proc/4243"
ln -s "$orphan_wt" "$fake_proc/4242/cwd"
printf 'Name:\tpnpm\nPPid:\t1\n' > "$fake_proc/4242/status"
printf 'pnpm\0dev\0' > "$fake_proc/4242/cmdline"
ln -s "$orphan_wt" "$fake_proc/4243/cwd"
printf 'Name:\tnode\nPPid:\t4321\n' > "$fake_proc/4243/status"
printf 'node\0watch\0' > "$fake_proc/4243/cmdline"
write_record "$state" 914 "{\"issue\":914,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":914,\"worktree\":\"$orphan_wt\",\"relays\":0}"
out="$(GH_PR_STATE=MERGED run_tick "$state" FLEET_PROC_ROOT="$fake_proc")"
grep -q "DRY: kill -TERM 4242" <<<"$out"
grep -q "DRY: fleetctl log 914 teardown: asked orphaned leftover process 4242 to stop (pnpm dev)" <<<"$out"
grep -q "DRY: git .*worktree remove $orphan_wt" <<<"$out"
pass "merged teardown politely stops an orphaned leftover process and logs it"
if grep -q "kill -TERM 4243" <<<"$out"; then false; fi
pass "a leftover process with a live parent is never signalled"

# A lane that is not merged/done never signals anything, even with the same
# orphan sitting in its worktree: teardown does not run for it at all, and the
# in-function status pin backs that up.
state="$(new_state)"
write_record "$state" 915 "{\"issue\":915,\"status\":\"merging\",\"tier\":\"routine\",\"pr\":915,\"worktree\":\"$orphan_wt\",\"relays\":0}"
out="$(GH_PR_STATE=OPEN run_tick "$state" FLEET_PROC_ROOT="$fake_proc")"
if grep -q "kill -TERM" <<<"$out"; then false; fi
if grep -q "asked orphaned leftover process" <<<"$out"; then false; fi
pass "a lane whose PR has not merged never signals any process"

# --- 20. Unit 3: red checks dispatch a fix agent with the check names in the brief ---

state="$(new_state)"
write_record "$state" 950 '{"issue":950,"status":"ci-red","tier":"routine","pr":950,"relays":0}'
printf '{"ts":"%s","issue":950,"msg":"ci-red: failing checks: lint,test"}\n' "$now_iso" > "$state/log.jsonl"
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"},{"name":"test","bucket":"fail"}]' run_tick "$state")"
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
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "DRY: herdr pane close w1:p7 (fleet-fix-955-ci-r1)" <<<"$out"
grep -q "DRY: herdr agent start fleet-fix-955-ci-r1" <<<"$out"
pass "a stale finished pane holding the next fix name is closed and the fix respawned"

# --- 23. a third same-cause failure parks with a question for Ben instead of trying again --

state="$(new_state)"
write_record "$state" 953 '{"issue":953,"status":"ci-red","tier":"routine","pr":953,"ci_fix_rounds":2,"relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 953 status=blocked" <<<"$out"
grep -qi "third time" <<<"$out"
if grep -q "herdr agent start fleet-fix" <<<"$out"; then false; fi
pass "a third same-cause failure parks the lane with a question for Ben instead of retrying again"

# --- 23b. rounds spent but the fresh check run is still in progress: no park -------
# Live 2026-08-26, issue 1975: the round-2 fix pushed its commit, GitHub
# started a fresh check run seventeen seconds later, and the next tick parked
# the lane as a third failure while that run was still in progress. Spent
# rounds plus a run in flight now mean "hand the lane back to the watcher",
# never "give up".

state="$(new_state)"
write_record "$state" 975 '{"issue":975,"status":"ci-red","tier":"routine","pr":975,"ci_fix_rounds":2,"relays":0}'
out="$(GH_CHECKS='[{"name":"build","bucket":"pending"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 975 status=pr-open" <<<"$out"
if grep -q "status=blocked" <<<"$out"; then false; fi
if grep -q "herdr agent start fleet-fix" <<<"$out"; then false; fi
if grep -q "DRY: needs-ben" <<<"$out"; then false; fi
pass "spent fix rounds with the fresh check run still in progress go back to pr-open instead of parking"

# --- 23c. the same staleness check also refuses to burn a round mid-way ------------

state="$(new_state)"
write_record "$state" 976 '{"issue":976,"status":"ci-red","tier":"routine","pr":976,"ci_fix_rounds":1,"relays":0}'
out="$(GH_CHECKS='[{"name":"build","bucket":"pending"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 976 status=pr-open" <<<"$out"
if grep -q "herdr agent start fleet-fix-976" <<<"$out"; then false; fi
pass "a check run still in progress stops a new fix round from being burned as well"

# --- 23d. a failed review whose fix was pushed after the round started: judged, not parked --

state="$(new_state)"
review_fix_spawned_iso="$(date -Iseconds -d '30 minutes ago')"
write_record "$state" 977 "{\"issue\":977,\"status\":\"qa-red\",\"tier\":\"routine\",\"pr\":977,\"qa_rounds\":1,\"qa_fix_rounds\":2,\"relays\":0,\"updated_at\":\"$review_fix_spawned_iso\"}"
out="$(GH_PR_LAST_COMMIT_ISO="$now_iso" run_tick "$state")"
grep -q "DRY: fleetctl set 977 status=pr-open" <<<"$out"
if grep -q "status=blocked" <<<"$out"; then false; fi
if grep -q "DRY: needs-ben" <<<"$out"; then false; fi
pass "a review fix pushed after the round started goes back to pr-open for judgment instead of parking"

# --- 23e. a genuine third strike parks AND actually reaches Ben's phone ------------
# The old park only wrote "parked with a question for Ben" to the log; no
# question was set on the record and no needs-ben message was ever sent.

state="$(new_state)"
write_record "$state" 978 '{"issue":978,"status":"ci-red","tier":"routine","pr":978,"ci_fix_rounds":2,"relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state")"
grep -q "DRY: fleetctl set 978 status=blocked" <<<"$out"
grep -q "DRY: needs-ben fleet-daemon issue 978: checks failed a third time in a row" <<<"$out"
grep -q "DRY: fleetctl set 978 question=checks failed a third time in a row" <<<"$out"
if grep -q "herdr agent start fleet-fix-978" <<<"$out"; then false; fi
pass "a genuine third strike parks the lane and files the question on Ben's phone and the record"

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
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state" FLEET_SPAWN_BUDGET=10)"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "DRY: herdr agent start fleet-fix-958-ci-r1" <<<"$out"
pass "a fresh lane is refused once only the recovery reserve is left, while a fix agent is still granted"

# --- 27. a lane needing recovery with the whole budget spent parks, reason spawn budget exhausted --

state="$(new_state)"
printf '{"ts":"%s","issue":959,"msg":"ci-red: failing checks: lint"}\n' "$now_iso" > "$state/log.jsonl"
printf '%s 10\n' "$(budget_cutoff_epoch_test)" > "$state/.spawn-count"
write_record "$state" 959 '{"issue":959,"status":"ci-red","tier":"routine","pr":959,"relays":0}'
out="$(GH_CHECKS='[{"name":"lint","bucket":"fail"}]' run_tick "$state" FLEET_SPAWN_BUDGET=10)"
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
grep -q "set 2001 status=done --pr-merged" "$SHIM_LOG_DIR/fleetctl.log"
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

# 49c. Ben's "merge" overrides the live-path park (his ruling, 2026-08-26):
# the merge proceeds and the override is logged loudly, naming the floor.
state="$(new_state)"
write_record "$state" 972 '{"issue":972,"status":"blocked","tier":"routine","pr":972,"blocked_reason":"code-complete, unverified: needs live-path proof","relays":0}'
echo "merge issue 972" > "$tmp/needs-ben/replies/reply-972.txt"
clear_logs
out="$(run_tick "$state")"
grep -q "DRY: gh pr merge 972 --squash --auto" <<<"$out"
grep -q "OVERRIDE: merge ran on Ben's explicit 'merge' instruction" <<<"$out"
grep -q "floor overridden: the code-complete-unverified park" <<<"$out"
grep -q "Ben replied 'merge': auto-merge enabled on PR #972" <<<"$out"
pass "a reply saying merge overrides the code-complete-unverified park, with the override logged by name (Ben's 2026-08-26 ruling)"

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

# --- 60. Ben's merge reply overrides the missing live-path proof (2026-08-26 ruling) ---

state="$(new_state)"
write_record "$state" 3020 '{"issue":3020,"status":"blocked","tier":"routine","pr":320,"spec":"docs/x.md","blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3020" > "$tmp/needs-ben/replies/reply-3020.txt"
clear_logs
out="$(GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS='' run_tick "$state")"
grep -q "DRY: gh pr merge 320 --squash --auto" <<<"$out"
grep -q "OVERRIDE: merge ran on Ben's explicit 'merge' instruction" <<<"$out"
grep -q "floor overridden: the missing live-path proof comment on user-facing PR #320" <<<"$out"
pass "Ben's merge reply on a user-facing PR without live-path proof proceeds with the override logged (his 2026-08-26 ruling)"

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

# --- 62a. Ben's merge override on a code-complete-unverified park, checked live ---
# (his explicit 2026-08-26 ruling): the merge is really enabled, the record is
# set the same way as a normal merge, the reply is marked handled, and the
# override is logged loudly with the floor named.

state="$(new_state)"
write_record "$state" 3050 '{"issue":3050,"status":"blocked","tier":"routine","pr":350,"spec":"docs/x.md","blocked_reason":"code-complete, unverified","relays":0}'
echo "merge issue 3050" > "$tmp/needs-ben/replies/reply-3050.txt"
clear_logs
run_tick_live "$state" >/dev/null
grep -q "pr merge 350 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "set 3050 status=merging" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "OVERRIDE: merge ran on Ben's explicit 'merge' instruction (his 2026-08-26 ruling) with the live-path proof skipped; floor overridden: the code-complete-unverified park" "$SHIM_LOG_DIR/fleetctl.log"
[ -f "$tmp/needs-ben/replies/reply-3050.txt.handled" ]
pass "Ben's merge override on a code-complete-unverified park really merges, marks the reply handled, and logs the override"

# --- 62b. Ben's merge override when the proof comment is missing, checked live ---

state="$(new_state)"
write_record "$state" 3051 '{"issue":3051,"status":"blocked","tier":"routine","pr":351,"spec":"docs/x.md","blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3051" > "$tmp/needs-ben/replies/reply-3051.txt"
clear_logs
run_tick_live "$state" GH_PR_FILES="apps/web/src/App.tsx" GH_PR_COMMENTS='' >/dev/null
grep -q "pr merge 351 --squash --auto" "$SHIM_LOG_DIR/gh.log"
grep -q "set 3051 status=merging" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "floor overridden: the missing live-path proof comment on user-facing PR #351" "$SHIM_LOG_DIR/fleetctl.log"
[ -f "$tmp/needs-ben/replies/reply-3051.txt.handled" ]
pass "Ben's merge override on a user-facing PR without proof really merges, marks the reply handled, and logs the override"

# --- 62c. a merge from Ben with no floor in the way logs no override line ---

state="$(new_state)"
write_record "$state" 3052 '{"issue":3052,"status":"blocked","tier":"routine","pr":352,"spec":"docs/x.md","blocked_reason":"needs a decision","relays":0}'
echo "merge issue 3052" > "$tmp/needs-ben/replies/reply-3052.txt"
clear_logs
run_tick_live "$state" GH_PR_FILES="docs/notes.md" GH_PR_COMMENTS='' >/dev/null
grep -q "pr merge 352 --squash --auto" "$SHIM_LOG_DIR/gh.log"
if grep -q "OVERRIDE" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "Ben's merge with no floor in the way merges normally, with no override line"

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

# --- 34e. the revisit prompt lists open follow-ups that mention the parent ---------
# Seen live 2026-08-26: with no list, the judge drafted issue 1983 duplicating
# the pre-existing piece 1970 almost word for word.

state="$(new_state)"
write_record "$state" 2140 '{"issue":2140,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2141","resliced_to":2141,"spec":"https://github.com/motioneso/fake/issues/2140"}'
write_record "$state" 2141 '{"issue":2141,"status":"merging","tier":"routine","pr":95,"relays":0}'
clear_logs
followups='[{"number":2142,"title":"Fake feature part 3 of #2140","body":"Cut earlier from #2140.\nCovers the delete path.\nDone when deletes round-trip.\nA fourth line that must not appear."}]'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE" GH_ISSUE_LIST_JSON="$followups")"
grep -q "issue list --repo motioneso/fake --state open --search #2140" "$SHIM_LOG_DIR/gh.log"
grep -q "OPEN issues that already mention #2140" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q "#2142: Fake feature part 3 of #2140" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q "Covers the delete path." "$SHIM_LOG_DIR/claude-prompts.log"
if grep -q "A fourth line that must not appear." "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
grep -q "FIRST line must be exactly: EXISTING #N" "$SHIM_LOG_DIR/claude-prompts.log"
pass "the revisit prompt shows the judge the open follow-ups that already mention the parent"

# --- 34f. an EXISTING answer reuses the offered follow-up, no new issue ------------

state="$(new_state)"
write_record "$state" 2150 '{"issue":2150,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2151","resliced_to":2151,"spec":"https://github.com/motioneso/fake/issues/2150"}'
write_record "$state" 2151 '{"issue":2151,"status":"merging","tier":"routine","pr":96,"relays":0}'
clear_logs
followups='[{"number":2152,"title":"Fake feature part 3 of #2150","body":"Cut earlier from #2150."}]'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="EXISTING #2152" GH_ISSUE_LIST_JSON="$followups")"
if grep -q "issue create" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -q "project item-add .* --url https://github.com/motioneso/fake/issues/2152" "$SHIM_LOG_DIR/gh.log"
grep -q "set 2150 blocked_reason=re-sliced automatically: remaining work is issue #2152 resliced_to=2152" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "log 2150 part #2151 merged; the next part already exists as issue #2152" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "log fleet parent revisit for issue #2150 reused the existing follow-up issue #2152" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "issue close 2150" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "set 2150 status=done" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "an EXISTING answer naming an offered follow-up promotes it to the board and repoints the parent, drafting nothing"

# --- 34g. an EXISTING answer naming an unoffered number changes nothing ------------

state="$(new_state)"
write_record "$state" 2160 '{"issue":2160,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2161","resliced_to":2161,"spec":"https://github.com/motioneso/fake/issues/2160"}'
write_record "$state" 2161 '{"issue":2161,"status":"merging","tier":"routine","pr":97,"relays":0}'
clear_logs
followups='[{"number":2162,"title":"Fake feature part 3 of #2160","body":"Cut earlier from #2160."}]'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="EXISTING #2999" GH_ISSUE_LIST_JSON="$followups")"
if grep -q "issue create" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "item-add" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "set 2160 " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
grep -q "warning: the parent-revisit answer named issue #2999, which is not one of the open follow-ups it was offered" "$SHIM_LOG_DIR/fleetctl.log"
pass "an EXISTING answer naming a number that was never offered only logs a warning and leaves the parent alone"

# --- 34h. an EXISTING answer below an explanation line is still honored ------------
# Seen live 2026-08-26: the judge explained itself on line 1 ("#1971 already
# covers the only remaining piece...") and put "EXISTING #1971" on line 3; the
# first-line-only check missed it and drafted a junk issue titled with the
# explanation sentence.

state="$(new_state)"
write_record "$state" 2170 '{"issue":2170,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2171","resliced_to":2171,"spec":"https://github.com/motioneso/fake/issues/2170"}'
write_record "$state" 2171 '{"issue":2171,"status":"merging","tier":"routine","pr":98,"relays":0}'
clear_logs
followups='[{"number":2172,"title":"Fake feature part 3 of #2170","body":"Cut earlier from #2170."}]'
answer=$'#2172 already covers the only remaining piece of the parent.\n\n  existing #2172'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="$answer" GH_ISSUE_LIST_JSON="$followups")"
if grep -q "issue create" "$SHIM_LOG_DIR/gh.log"; then false; fi
grep -q "project item-add .* --url https://github.com/motioneso/fake/issues/2172" "$SHIM_LOG_DIR/gh.log"
grep -q "set 2170 blocked_reason=re-sliced automatically: remaining work is issue #2172 resliced_to=2172" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "log 2170 part #2171 merged; the next part already exists as issue #2172" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "issue close 2170" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "set 2170 status=done" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "an EXISTING answer buried below an explanation line is still found, reused, and nothing new is drafted"

# --- 34i. a two-level chain: closing the mid parent revisits the top parent too ----
# Seen live 2026-08-26: closing 1965 stranded 1955 and 1349, which sat blocked
# on GitHub-closed work until a human noticed on the morning board.

state="$(new_state)"
write_record "$state" 2300 '{"issue":2300,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2301","resliced_to":2301,"spec":"https://github.com/motioneso/fake/issues/2300"}'
write_record "$state" 2301 '{"issue":2301,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2302","resliced_to":2302,"spec":"https://github.com/motioneso/fake/issues/2301"}'
write_record "$state" 2302 '{"issue":2302,"status":"merging","tier":"routine","pr":99,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE")"
grep -q "issue #2301 was split into parts" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q "issue #2300 was split into parts" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q "issue close 2301 --repo motioneso/fake --comment All parts of this issue are finished and merged" "$SHIM_LOG_DIR/gh.log"
grep -q "issue close 2300 --repo motioneso/fake --comment All parts of this issue are finished and merged" "$SHIM_LOG_DIR/gh.log"
grep -q "set 2301 status=done blocked_reason=" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2300 status=done blocked_reason=" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 2302 status=done" "$SHIM_LOG_DIR/fleetctl.log"
pass "closing a mid-chain parent revisits and closes the top parent in the same tick"

# --- 34j. the climb never fires when the ruling cuts a next part instead of DONE ---

state="$(new_state)"
write_record "$state" 2310 '{"issue":2310,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2311","resliced_to":2311,"spec":"https://github.com/motioneso/fake/issues/2310"}'
write_record "$state" 2311 '{"issue":2311,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2312","resliced_to":2312,"spec":"https://github.com/motioneso/fake/issues/2311"}'
write_record "$state" 2312 '{"issue":2312,"status":"merging","tier":"routine","pr":100,"relays":0}'
clear_logs
next_part=$'Fake feature part 3 of #2311\nEarlier parts delivered the read path. This part covers the delete path.'
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="$next_part" GH_ISSUE_CREATE_URL="https://github.com/motioneso/fake/issues/2313")"
grep -q "issue create --repo motioneso/fake --title Fake feature part 3 of #2311" "$SHIM_LOG_DIR/gh.log"
grep -q "set 2311 blocked_reason=re-sliced automatically: remaining work is issue #2313 resliced_to=2313" "$SHIM_LOG_DIR/fleetctl.log"
[ "$(grep -c "was split into parts" "$SHIM_LOG_DIR/claude-prompts.log")" = "1" ]
if grep -q "issue #2310 was split into parts" "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
if grep -q "issue close 2311" "$SHIM_LOG_DIR/gh.log"; then false; fi
if grep -q "issue close 2310" "$SHIM_LOG_DIR/gh.log"; then false; fi
pass "a next-part ruling on the mid parent never climbs to the top parent"

# --- 34k. the climb never fires when closing the parent FAILED ---------------------
# The leaf issue reads as already closed on GitHub, so its close-out succeeds
# without calling issue close; the only close attempt is the parent's, and it
# is the one made to fail.

state="$(new_state)"
write_record "$state" 2320 '{"issue":2320,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2321","resliced_to":2321,"spec":"https://github.com/motioneso/fake/issues/2320"}'
write_record "$state" 2321 '{"issue":2321,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2322","resliced_to":2322,"spec":"https://github.com/motioneso/fake/issues/2321"}'
write_record "$state" 2322 '{"issue":2322,"status":"merging","tier":"routine","pr":101,"relays":0}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE" GH_ISSUE_STATE=CLOSED GH_ISSUE_CLOSE_EXIT=1)"
grep -q "warning: all parts of issue #2321 look merged but closing it failed" "$SHIM_LOG_DIR/fleetctl.log"
[ "$(grep -c "^issue close" "$SHIM_LOG_DIR/gh.log")" = "1" ]
if grep -q "issue #2320 was split into parts" "$SHIM_LOG_DIR/claude-prompts.log"; then false; fi
if grep -q "set 2321 status=done" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
if grep -q "set 2320 " "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a failed parent close never climbs further and leaves the level above untouched"

# --- 34l. a hand-made pointer cycle hits the depth guard instead of hanging --------
# Two records point at each other; the shims never write status back, so
# nothing else would ever break the loop.

state="$(new_state)"
write_record "$state" 2330 '{"issue":2330,"status":"blocked","tier":"routine","relays":2,"blocked_reason":"re-sliced automatically: remaining work is issue #2331","resliced_to":2331,"spec":"https://github.com/motioneso/fake/issues/2330"}'
write_record "$state" 2331 '{"issue":2331,"status":"merging","tier":"routine","pr":103,"relays":0,"resliced_to":2330,"spec":"https://github.com/motioneso/fake/issues/2331"}'
clear_logs
out="$(run_tick_live "$state" GH_PR_STATE=MERGED CLAUDE_ANSWER="DONE")"
grep -q "climbed 10 levels without reaching the top" "$SHIM_LOG_DIR/fleetctl.log"
[ "$(grep -c "was split into parts" "$SHIM_LOG_DIR/claude-prompts.log")" = "10" ]
pass "a cyclic re-slice pointer stops at the depth guard with one warning instead of looping"


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

# 66. log_if_new compares only the lane's LAST log line: the same alarm buried
# under a newer, different line must be logged again. This pins the semantics
# after the per-tick log map replaced the per-call full read of log.jsonl.
state="$(new_state)"
{
  printf '{"ts":"%s","issue":3303,"msg":"ALARM: this lane has relayed 6 times under the standing resume rule; it keeps handing off without finishing - worth a human look"}\n' "$now_iso"
  printf '{"ts":"%s","issue":3303,"msg":"checks pending"}\n' "$now_iso"
} > "$state/log.jsonl"
write_record "$state" 3303 "{\"issue\":3303,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-3303\",\"relays\":6,\"relay_cap_waived\":1,\"spec\":\"https://github.com/motioneso/fake/issues/3303\",\"updated_at\":\"$now_iso\"}"
out="$(run_tick "$state")"
grep -q "DRY: fleetctl log 3303 ALARM: this lane has relayed 6 times" <<<"$out"
pass "log_if_new re-logs when the identical line is no longer the lane's last"

# --- 67. Step 11b: needs-ben directory hygiene ------------------------------------

# 67a. Handled replies (any age) and 14-day-old sent/reply files are archived;
# fresh live files stay put.
state="$(new_state)"
write_record "$state" 3400 '{"issue":3400,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
echo "issue 3400: already acted on" > "$tmp/needs-ben/replies/reply-done.txt.handled"
echo "issue 3400: an ancient reply" > "$tmp/needs-ben/replies/reply-ancient.txt"
touch -d '20 days ago' "$tmp/needs-ben/replies/reply-ancient.txt"
echo "issue 3400: an ancient question" > "$tmp/needs-ben/sent/entry-ancient.msg"
touch -d '20 days ago' "$tmp/needs-ben/sent/entry-ancient.msg"
echo "issue 3400: a fresh question" > "$tmp/needs-ben/sent/entry-fresh-3400.msg"
out="$(run_tick "$state")"
grep -q "DRY: mv $tmp/needs-ben/replies/reply-done.txt.handled" <<<"$out"
grep -q "DRY: mv $tmp/needs-ben/replies/reply-ancient.txt" <<<"$out"
grep -q "DRY: mv $tmp/needs-ben/sent/entry-ancient.msg" <<<"$out"
if grep -q "DRY: mv $tmp/needs-ben/sent/entry-fresh-3400.msg" <<<"$out"; then false; fi
pass "old and handled needs-ben files are archived; fresh ones are left alone"
rm -f "$tmp/needs-ben/replies/reply-done.txt.handled" "$tmp/needs-ben/replies/reply-ancient.txt" \
  "$tmp/needs-ben/sent/entry-ancient.msg" "$tmp/needs-ben/sent/entry-fresh-3400.msg"

# 67b. An archived reply is out of the scan: a matching reply sitting in
# archive/replies must never act on the lane (pins the -maxdepth 1 scan and
# the archive/ location outside every scanned path).
state="$(new_state)"
write_record "$state" 3401 '{"issue":3401,"status":"blocked","tier":"routine","blocked_reason":"needs a decision","relays":0}'
mkdir -p "$tmp/needs-ben/archive/replies"
echo "resume issue 3401" > "$tmp/needs-ben/archive/replies/reply-3401.txt"
out="$(run_tick "$state")"
if grep -q "Ben replied" <<<"$out"; then false; fi
if grep -q "DRY: fleetctl set 3401 status=queued" <<<"$out"; then false; fi
pass "a reply already moved to archive is never scanned or acted on"

# --- 68. Step 12: an honest "too big to review" verdict ---------------------------

# 68a. Every QA brief offers the too-big verdict alongside pass and fail (pinned
# via the reviewer-respawn path, which writes a normal, non-chunked brief).
state="$(new_state)"
stale_review_iso="$(date -Iseconds -d '20 minutes ago')"
write_record "$state" 3502 "{\"issue\":3502,\"status\":\"qa\",\"tier\":\"routine\",\"pr\":3502,\"reviewer\":\"fleet-qa-3502-r1\",\"qa_rounds\":0,\"relays\":0,\"updated_at\":\"$stale_review_iso\"}"
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-3502-r1-retry" <<<"$out"
grep -q "status=qa-too-big" "$state/briefs/brief-3502-qa-r1-retry.md"
if grep -q "few files at a time" "$state/briefs/brief-3502-qa-r1-retry.md"; then false; fi
pass "a normal QA brief offers the too-big verdict but not the piece-by-piece instructions"

# 68b. The first too-big verdict never phones Ben: it spawns one fresh reviewer
# told to review piece by piece, and marks the lane so a second too-big parks.
state="$(new_state)"
write_record "$state" 3500 '{"issue":3500,"status":"qa-too-big","tier":"routine","pr":3500,"branch":"feat/3500","worktree":"/tmp/wt-3500","qa_rounds":1,"relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-qa-3500-r2-chunked" <<<"$out"
grep -q "DRY: fleetctl set 3500 status=qa reviewer=fleet-qa-3500-r2-chunked chunked_review=1" <<<"$out"
grep -q "few files at a time" "$state/briefs/brief-3500-qa-r2-chunked.md"
grep -q "status=qa-too-big" "$state/briefs/brief-3500-qa-r2-chunked.md"
if grep -q "DRY: needs-ben" <<<"$out"; then false; fi
pass "the first too-big verdict spawns a piece-by-piece reviewer instead of phoning Ben"

# 68c. When the piece-by-piece reviewer ALSO says too big, the lane parks and
# the merge call goes to Ben - the only point a human enters this path.
state="$(new_state)"
write_record "$state" 3501 '{"issue":3501,"status":"qa-too-big","tier":"routine","pr":3501,"branch":"feat/3501","worktree":"/tmp/wt-3501","qa_rounds":2,"chunked_review":1,"relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: fleetctl set 3501 status=blocked" <<<"$out"
grep -q "too big to review honestly, even piece by piece" <<<"$out"
grep -q "DRY: needs-ben fleet-daemon issue 3501: the review says this change is too big to review honestly, even piece by piece - the merge call is yours" <<<"$out"
if grep -q "DRY: herdr agent start" <<<"$out"; then false; fi
pass "a second too-big verdict parks the lane with the merge call for Ben"

# --- 69. FLEET_SANDBOX flag wraps spawned agents ----------------------------------

state="$(new_state)"
write_record "$state" 3601 '{"issue":3601,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state" FLEET_SANDBOX=1)"
grep -q "DRY: herdr agent start fleet-lane-3601" <<<"$out"
grep -q "DRY: sandbox: fleet-lane-3601 runs inside scripts/agent-sandbox.sh" <<<"$out"
pass "FLEET_SANDBOX=1 marks the spawned agent as sandboxed"

state="$(new_state)"
write_record "$state" 3602 '{"issue":3602,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-lane-3602" <<<"$out"
if grep -q "DRY: sandbox" <<<"$out"; then false; fi
pass "the sandbox stays off unless FLEET_SANDBOX=1 is set"

# --- 70. A pane that is not ready yet gets a brief retry, not a dead lane ---------
# Seen live 2026-08-26 (07:36, 07:47): the pane opens, but its shell has not
# finished starting when the agent start lands, and herdr answers
# agent_pane_busy. Only that error is worth retrying on the same pane.

busy_msg='error: agent_pane_busy: agent target pane w1:p9 is not an available shell'

# 70a. Busy once, then fine: the spawn succeeds and the pane stays open.
state="$(new_state)"
write_record "$state" 3701 '{"issue":3701,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=1 HERDR_AGENT_START_STDERR="$busy_msg" FLEET_SPAWN_RETRY_SECONDS=0 2>&1)"
grep -q "fleet-tick: pane not ready for fleet-lane-3701, retrying (attempt 2 of 3)" <<<"$out"
[ "$(grep -c "agent start fleet-lane-3701" "$SHIM_LOG_DIR/herdr.log")" = "2" ]
if grep -q "pane close" "$SHIM_LOG_DIR/herdr.log"; then false; fi
grep -q "set 3701 status=building" "$SHIM_LOG_DIR/fleetctl.log"
pass "a pane-not-ready start is retried on the same pane and the second try succeeds"

# 70b. Busy every time: three attempts, then today's failure path (last
# stderr in the journal, pane closed, lane not marked building).
state="$(new_state)"
write_record "$state" 3702 '{"issue":3702,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=99 HERDR_AGENT_START_STDERR="$busy_msg" FLEET_SPAWN_RETRY_SECONDS=0 2>&1)"
grep -q "retrying (attempt 2 of 3)" <<<"$out"
grep -q "retrying (attempt 3 of 3)" <<<"$out"
[ "$(grep -c "agent start fleet-lane-3702" "$SHIM_LOG_DIR/herdr.log")" = "3" ]
grep -q "herdr agent start failed for fleet-lane-3702: error: agent_pane_busy" <<<"$out"
grep -q "pane close w1:p9" "$SHIM_LOG_DIR/herdr.log"
if grep -q "set 3702 status=building" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a pane busy on every try gives up after 3 attempts, closes the pane, and fails"

# 70c. Any other start error is not retried at all.
state="$(new_state)"
write_record "$state" 3703 '{"issue":3703,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=99 HERDR_AGENT_START_STDERR='error: something else broke' FLEET_SPAWN_RETRY_SECONDS=0 2>&1)"
if grep -q "retrying" <<<"$out"; then false; fi
[ "$(grep -c "agent start fleet-lane-3703" "$SHIM_LOG_DIR/herdr.log")" = "1" ]
grep -q "herdr agent start failed for fleet-lane-3703: error: something else broke" <<<"$out"
grep -q "pane close w1:p9" "$SHIM_LOG_DIR/herdr.log"
pass "a start failing for any other reason fails once, with no retry"

# 70d. A start that times out waiting for readiness, when an agent under that
# exact name really is running: the start SUCCEEDED and only the ready signal
# was late. Live on lane 1884 (2026-08-27) this was misread five times in a
# row, killing five working agents.

timeout_msg='herdr agent start failed for fleet-lane-3704 {"error":{"code":"timeout","message":"timed out waiting for agent startup"}}'
agents_late='{"result":{"agents":[{"name":"fleet-lane-3704","agent_status":"working","pane_id":"w1:p9"}]}}'

state="$(new_state)"
write_record "$state" 3704 '{"issue":3704,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=99 HERDR_AGENT_START_STDERR="$timeout_msg" HERDR_AGENTS_JSON_AFTER_START="$agents_late" FLEET_SPAWN_RETRY_SECONDS=0 2>&1)"
grep -q "fleet-lane-3704 was slow to report ready but it did start" <<<"$out"
[ "$(grep -c "agent start fleet-lane-3704" "$SHIM_LOG_DIR/herdr.log")" = "1" ]
if grep -q "pane close" "$SHIM_LOG_DIR/herdr.log"; then false; fi
grep -q "set 3704 status=building" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "set 3704 agent_model=" "$SHIM_LOG_DIR/fleetctl.log"
pass "a readiness timeout with the agent really running counts as a successful start"

# 70e. Same timeout, but no agent of that name is running: the old failure
# path stands (reason in the journal, pane closed, lane not building).
state="$(new_state)"
write_record "$state" 3705 '{"issue":3705,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=99 HERDR_AGENT_START_STDERR="${timeout_msg//3704/3705}" FLEET_SPAWN_RETRY_SECONDS=0 FLEET_PANE_NAME_WAIT_SECONDS=0 2>&1)"
if grep -q "was slow to report ready" <<<"$out"; then false; fi
grep -q "herdr agent start failed for fleet-lane-3705" <<<"$out"
grep -q "pane close w1:p9" "$SHIM_LOG_DIR/herdr.log"
if grep -q "set 3705 status=building" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a readiness timeout with no such agent running still fails the spawn"

# 70e2. The name shows up a moment after the start gave up: asking once was
# too early, and each premature "failure" closed a pane that was about to work
# (lane 1319's plan writer, six ticks running, 2026-08-27).
state="$(new_state)"
write_record "$state" 3706 '{"issue":3706,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
out="$(run_tick_live "$state" HERDR_AGENT_START_FAILS=99 HERDR_AGENT_START_STDERR="${timeout_msg//3704/3706}" \
  HERDR_AGENTS_JSON_AFTER_START="${agents_late//3704/3706}" HERDR_AGENT_APPEARS_AFTER_LISTS=2 \
  FLEET_SPAWN_RETRY_SECONDS=0 FLEET_PANE_NAME_WAIT_SECONDS=6 2>&1)"
grep -q "fleet-lane-3706 was slow to report ready but it did start" <<<"$out"
if grep -q "pane close" "$SHIM_LOG_DIR/herdr.log"; then false; fi
grep -q "set 3706 status=building" "$SHIM_LOG_DIR/fleetctl.log"
pass "a name that appears a moment later still counts as a started agent"

# 70f. The readiness wait is longer than herdr's own 30s default, overridable,
# and never asks for more than herdr's documented maximum.
state="$(new_state)"
write_record "$state" 3706 '{"issue":3706,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q -- "--timeout 120000" <<<"$out"
out="$(run_tick "$state" FLEET_AGENT_READY_TIMEOUT_MS=200000)"
grep -q -- "--timeout 200000" <<<"$out"
out="$(run_tick "$state" FLEET_AGENT_READY_TIMEOUT_MS=999999)"
grep -q -- "--timeout 300000" <<<"$out"
pass "the readiness wait defaults to 120s, can be overridden, and is capped at 300s"

# --- 71. Stranded-push guard: a fix round's commits must reach the remote ---------
# Seen live on lane 1970: the fix agent committed in the worktree but never
# pushed, checks re-ran against the old remote tip, failed identically, and a
# whole fresh fix round was burned.

# 71a. Local commits ahead of the recorded remote tip get pushed (plain push)
# and logged; a round that moved the remote raises no alarm.
state="$(new_state)"
wt_ahead="$tmp/wt-4001"
mkdir -p "$wt_ahead"
git -C "$wt_ahead" init -q
git -C "$wt_ahead" -c user.email=t@t -c user.name=t commit --allow-empty -qm base
base_sha="$(git -C "$wt_ahead" rev-parse HEAD)"
git -C "$wt_ahead" -c user.email=t@t -c user.name=t commit --allow-empty -qm fix
write_record "$state" 4001 "{\"issue\":4001,\"status\":\"ci-red\",\"tier\":\"routine\",\"pr\":4001,\"branch\":\"fleet/lane-4001\",\"worktree\":\"$wt_ahead\",\"agent\":\"fleet-fix-4001-ci-r1\",\"ci_fix_rounds\":1,\"fix_round_base\":\"$base_sha\",\"relays\":0}"
out="$(GIT_LSREMOTE_OUT="$base_sha	refs/heads/fleet/lane-4001" run_tick "$state")"
grep -q "DRY: git -C $wt_ahead push origin fleet/lane-4001" <<<"$out"
grep -q "the fix round left commits unpushed in the worktree; the daemon pushed them to origin/fleet/lane-4001" <<<"$out"
if grep -q "remote branch exactly where it started" <<<"$out"; then false; fi
if grep -q "push --force\|push -f" <<<"$out"; then false; fi
grep -q "the fix agent finished and its work is on origin/fleet/lane-4001; the lane goes back for review" <<<"$out"
pass "commits a fix agent left unpushed are pushed (never force) and logged"

# 71b. A round that left the remote tip exactly where it started raises the
# loud line; nothing is pushed.
state="$(new_state)"
wt_noop="$tmp/wt-4002"
mkdir -p "$wt_noop"
git -C "$wt_noop" init -q
git -C "$wt_noop" -c user.email=t@t -c user.name=t commit --allow-empty -qm base
noop_sha="$(git -C "$wt_noop" rev-parse HEAD)"
write_record "$state" 4002 "{\"issue\":4002,\"status\":\"ci-red\",\"tier\":\"routine\",\"pr\":4002,\"branch\":\"fleet/lane-4002\",\"worktree\":\"$wt_noop\",\"agent\":\"fleet-fix-4002-ci-r1\",\"ci_fix_rounds\":1,\"fix_round_base\":\"$noop_sha\",\"relays\":0}"
out="$(GIT_LSREMOTE_OUT="$noop_sha	refs/heads/fleet/lane-4002" run_tick "$state")"
grep -q "ALARM: the fix round ended with the remote branch exactly where it started" <<<"$out"
if grep -q "push origin" <<<"$out"; then false; fi
if grep -q "the fix agent finished and its work is on" <<<"$out"; then false; fi
pass "a fix round that never moved the remote raises the loud no-op alarm"

# 71c. A fix agent that pushed its own work: nothing to push here, no alarm,
# and the log says plainly that the round succeeded. Without this line the
# only trace of a successful fix round was a bare cleared stamp (lane 1884,
# 2026-08-27).
state="$(new_state)"
wt_pushed="$tmp/wt-4005"
mkdir -p "$wt_pushed"
git -C "$wt_pushed" init -q
git -C "$wt_pushed" -c user.email=t@t -c user.name=t commit --allow-empty -qm base
old_base="$(git -C "$wt_pushed" rev-parse HEAD)"
git -C "$wt_pushed" -c user.email=t@t -c user.name=t commit --allow-empty -qm fix
pushed_sha="$(git -C "$wt_pushed" rev-parse HEAD)"
write_record "$state" 4005 "{\"issue\":4005,\"status\":\"ci-red\",\"tier\":\"routine\",\"pr\":4005,\"branch\":\"fleet/lane-4005\",\"worktree\":\"$wt_pushed\",\"agent\":\"fleet-fix-4005-ci-r1\",\"ci_fix_rounds\":1,\"fix_round_base\":\"$old_base\",\"relays\":0}"
out="$(GIT_LSREMOTE_OUT="$pushed_sha	refs/heads/fleet/lane-4005" run_tick "$state")"
grep -q "the fix agent finished and its work is on origin/fleet/lane-4005; the lane goes back for review" <<<"$out"
if grep -q "push origin" <<<"$out"; then false; fi
if grep -q "remote branch exactly where it started" <<<"$out"; then false; fi
pass "a fix round whose work reached the remote says so in the log"

# --- 72. Idle-corpse guard: an idle agent with live work in its worktree is held --
# Seen live on lanes 1987 and 1982: an agent launched a long test run in the
# background, went idle, the daemon reaped the pane, and the sandbox death
# killed the still-running test.

# 72a/72b. Held while a process lives in the worktree; counted done once it exits.
state="$(new_state)"
wt_busy="$tmp/wt-4003"
mkdir -p "$wt_busy"
(cd "$wt_busy" && exec sleep 300) &
busy_pid=$!
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 4003 "{\"issue\":4003,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4003\",\"worktree\":\"$wt_busy\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4003","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "agent looks idle but a process is still running in its worktree; holding" <<<"$out"
grep -q "idle_hold_since=" <<<"$out"
if grep -q "closing the dead session" <<<"$out"; then false; fi
pass "an idle agent with a live worktree process is held, not counted done"

kill "$busy_pid" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null || true
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "closing the dead session and treating the agent as gone" <<<"$out"
if grep -q "still running in its worktree; holding" <<<"$out"; then false; fi
pass "once the worktree process exits, the idle agent is counted done as before"

# 72c. The 45-minute cap: a hold that old gives up loudly and the normal
# done-handling proceeds even though the process is still running.
state="$(new_state)"
wt_capped="$tmp/wt-4004"
mkdir -p "$wt_capped"
(cd "$wt_capped" && exec sleep 300) &
capped_pid=$!
hold_since=$(( $(date +%s) - 3000 ))
write_record "$state" 4004 "{\"issue\":4004,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4004\",\"worktree\":\"$wt_capped\",\"relays\":0,\"updated_at\":\"$stale_iso\",\"idle_hold_since\":$hold_since}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4004","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "ALARM: the agent has looked idle for 45 minutes while a process kept running in its worktree" <<<"$out"
grep -q "closing the dead session and treating the agent as gone" <<<"$out"
pass "after 45 minutes of holds the guard releases loudly and done-handling proceeds"
kill "$capped_pid" 2>/dev/null || true
wait "$capped_pid" 2>/dev/null || true

# 72d/72e. The agent session's own processes never hold the lane. Live chain
# on this box: herdr -> bwrap (sandbox wrapper) -> claude (the session) ->
# actual work. A session merely parked at its prompt (bwrap + claude only)
# must be counted done at once; a child the session left running must hold.
# Stand-in scripts named bwrap and claude give real processes those comms.
fake_dir="$tmp/fakeprocs"
mkdir -p "$fake_dir"
cat >"$fake_dir/claude" <<'EOF'
#!/bin/bash
# Stands in for the agent session: comm "claude", parent comm "bwrap".
# The shebang must name bash directly: an env shebang re-execs bash and
# the process name would read "bash" instead of the script's own name.
if [ -n "${FAKE_AGENT_CHILD:-}" ]; then
  sleep 300 &
  echo $! >> "$FAKE_PID_FILE"
  wait
else
  # Idle at its prompt: block without spawning any child process.
  read -r _ < "$FAKE_FIFO"
fi
EOF
cat >"$fake_dir/bwrap" <<'EOF'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
"$dir/claude" &
echo $! >> "$FAKE_PID_FILE"
wait
EOF
chmod +x "$fake_dir/claude" "$fake_dir/bwrap"

# 72d. Only the wrapper and the parked session live in the worktree: no hold.
state="$(new_state)"
wt_parked="$tmp/wt-4005"
mkdir -p "$wt_parked"
fifo_parked="$tmp/fake-fifo-4005"
mkfifo "$fifo_parked"
pids_parked="$tmp/fake-pids-4005"
: > "$pids_parked"
(cd "$wt_parked" && exec env FAKE_FIFO="$fifo_parked" FAKE_PID_FILE="$pids_parked" "$fake_dir/bwrap") &
parked_wrap_pid=$!
sleep 1
write_record "$state" 4005 "{\"issue\":4005,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4005\",\"worktree\":\"$wt_parked\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4005","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "closing the dead session and treating the agent as gone" <<<"$out"
if grep -q "still running in its worktree; holding" <<<"$out"; then false; fi
pass "the sandbox wrapper and the parked agent session alone never hold the lane"
kill "$parked_wrap_pid" 2>/dev/null || true
while read -r p; do kill "$p" 2>/dev/null || true; done < "$pids_parked"
wait "$parked_wrap_pid" 2>/dev/null || true

# 72e. The same chain plus one child the session left running: held.
state="$(new_state)"
wt_child="$tmp/wt-4006"
mkdir -p "$wt_child"
pids_child="$tmp/fake-pids-4006"
: > "$pids_child"
(cd "$wt_child" && exec env FAKE_AGENT_CHILD=1 FAKE_PID_FILE="$pids_child" "$fake_dir/bwrap") &
child_wrap_pid=$!
sleep 1
write_record "$state" 4006 "{\"issue\":4006,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4006\",\"worktree\":\"$wt_child\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4006","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
grep -q "agent looks idle but a process is still running in its worktree; holding" <<<"$out"
if grep -q "closing the dead session" <<<"$out"; then false; fi
pass "a child process the agent session left running still holds the lane"
kill "$child_wrap_pid" 2>/dev/null || true
while read -r p; do kill "$p" 2>/dev/null || true; done < "$pids_child"
wait "$child_wrap_pid" 2>/dev/null || true

# --- 73. a plan-less lane sends one spec-writer per budget window ------------------

state="$(new_state)"
write_record_without_plan "$state" 520 '{"issue":520,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/520"}'
out="$(run_tick "$state")"
grep -q "written-plan rule: not dispatching" <<<"$out"
grep -q "DRY: herdr agent start fleet-spec-520" <<<"$out"
if grep -q "herdr agent start fleet-lane-520" <<<"$out"; then false; fi
spec_brief="$state/briefs/brief-520-spec.md"
grep -q "FIRST line is" "$spec_brief"
grep -q "plain English" "$spec_brief"
grep -q "Do not create, edit, or delete any file" "$spec_brief"
pass "a plan-less lane gets one spec-writer sent to draft the SPEC comment"

out="$(run_tick "$state")"
if grep -q "herdr agent start fleet-spec-520" <<<"$out"; then false; fi
pass "the same budget window never sends a second spec-writer for the same lane"

# --- 73b. once the SPEC comment exists, the gate opens and the builder dispatches ---

touch -d '31 minutes ago' "$state/.no-spec-520"
out="$(run_tick "$state" GH_SPEC_COMMENT_COUNT=1)"
grep -q "DRY: herdr agent start fleet-lane-520" <<<"$out"
if grep -q "fleet-spec-520" <<<"$out"; then false; fi
pass "once the SPEC comment exists, the gate opens and the real builder dispatches"

# --- 73c. GitHub refusing to answer is not proof that no plan exists ---------------
# A rate-limited comment lookup used to read as "no plan", which spawned a
# redundant planning agent and held back a lane that did have a plan.

state="$(new_state)"
write_record_without_plan "$state" 521 '{"issue":521,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/521"}'
out="$(run_tick "$state" GH_SPEC_COMMENT_COUNT=1 GH_ISSUE_VIEW_STDERR='API rate limit exceeded' GH_ISSUE_VIEW_EXIT=1)"
grep -q "cannot check for a written plan" <<<"$out"
if grep -q "written-plan rule: not dispatching" <<<"$out"; then false; fi
if grep -q "herdr agent start fleet-spec-521" <<<"$out"; then false; fi
if grep -q "herdr agent start fleet-lane-521" <<<"$out"; then false; fi
[ ! -f "$state/.no-spec-521" ]
pass "a rate-limited plan check leaves the lane queued, with no planning agent and no cached no-plan answer"

# --- 73d. a tick already starved does not ask about plans at all -------------------

state="$(new_state)"
# The pull-request lane is numbered lower so it is handled first and marks the
# tick starved before the queued lane's plan check runs.
write_record "$state" 519 '{"issue":519,"status":"pr-open","tier":"routine","pr":519,"relays":0}'
write_record_without_plan "$state" 522 '{"issue":522,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/522"}'
out="$(run_tick "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded')"
if grep -q "herdr agent start fleet-spec-522" <<<"$out"; then false; fi
[ ! -f "$state/.no-spec-522" ]
pass "a starved tick asks nothing about plans and writes no no-plan answer"

# --- 74. zero check runs on the head commit: watch first, deputy after ten minutes --

state="$(new_state)"
write_record "$state" 530 '{"issue":530,"status":"pr-open","tier":"routine","pr":530,"branch":"fleet/lane-530","relays":0}'
out="$(GH_API_PR_SHA=deadbeef GH_API_CHECKS='[]' run_tick "$state")"
grep -q "no check runs at all yet; watching" <<<"$out"
if grep -q "deputy for lane 530" <<<"$out"; then false; fi
[ -f "$state/.no-checks-530" ]
pass "zero check runs starts the ten-minute watch without asking anyone"

echo "$(( $(date +%s) - 700 ))" > "$state/.no-checks-530"
out="$(GH_API_PR_SHA=deadbeef GH_API_CHECKS='[]' run_tick "$state")"
grep -q "deputy for lane 530: GitHub has created NO check runs" <<<"$out"
pass "ten minutes with zero check runs asks the deputy"

echo "$(( $(date +%s) - 700 ))" > "$state/.no-checks-530"
out="$(GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' run_tick "$state")"
if grep -q "deputy for lane 530" <<<"$out"; then false; fi
if [ -f "$state/.no-checks-530" ]; then false; fi
pass "runs that exist but sit queued are normal slowness, and the watch is cleared"

# --- 74b. a RETRIGGER ruling pushes one empty commit, plainly, and counts it -------

state="$(new_state)"
wt_531="$tmp/wt-531"
mkdir -p "$wt_531"
write_record "$state" 531 "{\"issue\":531,\"status\":\"pr-open\",\"tier\":\"routine\",\"pr\":531,\"branch\":\"fleet/lane-531\",\"worktree\":\"$wt_531\",\"relays\":0}"
echo "$(( $(date +%s) - 700 ))" > "$state/.no-checks-531"
clear_logs
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[]' CLAUDE_ANSWER=RETRIGGER >/dev/null
grep -q "RETRIGGER" "$SHIM_LOG_DIR/claude-prompts.log"
grep -q -- "-C $wt_531 commit --allow-empty -m ci: retrigger checks" "$SHIM_LOG_DIR/git.log"
grep -q -- "-C $wt_531 push origin HEAD" "$SHIM_LOG_DIR/git.log"
if grep -qE -- "--force|push -f" "$SHIM_LOG_DIR/git.log"; then false; fi
grep -q "set 531 checks_retriggers=1" "$SHIM_LOG_DIR/fleetctl.log"
if [ -f "$state/.no-checks-531" ]; then false; fi
pass "a RETRIGGER ruling pushes one empty commit plainly, never force, and counts the nudge"

# --- 74c. two nudges is the cap: the third zero-runs spell parks with a question ----

state="$(new_state)"
write_record "$state" 532 '{"issue":532,"status":"pr-open","tier":"routine","pr":532,"branch":"fleet/lane-532","checks_retriggers":2,"relays":0}'
echo "$(( $(date +%s) - 700 ))" > "$state/.no-checks-532"
out="$(GH_API_PR_SHA=deadbeef GH_API_CHECKS='[]' run_tick "$state")"
grep -q "DRY: fleetctl set 532 status=blocked" <<<"$out"
grep -q "even after 2 empty-commit nudges" <<<"$out"
grep -q "DRY: needs-ben fleet-daemon issue 532" <<<"$out"
if grep -q "deputy for lane 532" <<<"$out"; then false; fi
pass "after two nudges the lane parks with a question instead of nudging forever"

# --- 74d. the real record tool accepts and stores the retrigger counter ------------

fctl_state="$(mktemp -d "$tmp/fctl-XXXX")"
JARV1S_FLEET_STATE="$fctl_state" node "$tool_root/fleetctl.mjs" add 900 spec=docs/x.md tier=routine >/dev/null
JARV1S_FLEET_STATE="$fctl_state" node "$tool_root/fleetctl.mjs" set 900 checks_retriggers=1 >/dev/null
[ "$(jq -r '.checks_retriggers' "$fctl_state/tasks/900.json")" = "1" ]
pass "the real record tool accepts and stores the retrigger counter"

# --- 75. judgeModel and judgeEffort ride every judgment call -----------------------

state="$(new_state)"
write_record "$state" 540 '{"issue":540,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
printf '{"deputyEnabled": true, "judgeModel": "strong-model", "judgeEffort": "high"}\n' > "$state/settings.json"
out="$(run_tick "$state")"
grep -q "DRY: claude -p --model strong-model --effort high \[deputy for lane 540" <<<"$out"
pass "judgeModel and judgeEffort from settings ride the judgment call"

state="$(new_state)"
write_record "$state" 541 '{"issue":541,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
out="$(run_tick "$state")"
grep -q "DRY: claude -p \[deputy for lane 541" <<<"$out"
pass "with no judgeModel set the judgment command is untouched"

state="$(new_state)"
write_record "$state" 542 '{"issue":542,"status":"blocked","tier":"routine","blocked_reason":"stuck on a decision","relays":0}'
printf '{"deputyEnabled": true, "judgeModel": "settings-model", "judgeEffort": "high"}\n' > "$state/settings.json"
out="$(run_tick "$state" FLEET_JUDGE_MODEL=env-model)"
grep -q -- "--model env-model" <<<"$out"
if grep -q -- "--effort" <<<"$out"; then false; fi
pass "a judge model pinned by environment does not inherit the settings effort (pin both or neither)"

# --- 76. a building lane whose PR already merged is routed to teardown, not restarted --

# Seen live on lane 1971 (2026-08-25): a deputy re-queue left the lane
# "building" while its pull request had already merged, and the daemon
# restarted a build agent for finished work. Merged PR + building lane must
# route to the merging handler, never to a restart.

# 76a. merged PR: lane goes to merging, no judgment call, no agent spawned.
state="$(new_state)"
stale_iso="$(date -Iseconds -d '40 minutes ago')"
write_record "$state" 4200 "{\"issue\":4200,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"pr\":4200,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=MERGED run_tick "$state")"
grep -q "DRY: fleetctl set 4200 status=merging" <<<"$out"
grep -q "already merged" <<<"$out"
pass "a building lane whose PR is merged is routed to the merging handler"
if grep -q "DRY: herdr agent start" <<<"$out"; then false; fi
pass "no build agent is respawned for a building lane whose PR is merged"
if grep -q "judgment for lane 4200" <<<"$out"; then false; fi
pass "the dead-agent restart judgment is never asked when the PR is merged"

# 76b. no PR number: the lane behaves exactly as before (dead-lane judgment),
# and GitHub is never asked about a pull request for it.
state="$(new_state)"
clear_logs
write_record "$state" 4201 "{\"issue\":4201,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=MERGED run_tick "$state")"
grep -q "DRY: claude -p \[judgment for lane 4201" <<<"$out"
if grep -q "pulls/" "$SHIM_LOG_DIR/gh.log" 2>/dev/null; then false; fi
if grep -q "pr view" "$SHIM_LOG_DIR/gh.log" 2>/dev/null; then false; fi
pass "a building lane with no PR number gains no GitHub question and behaves as before"

# 76c. starved tick: GitHub refuses to answer the merged question, so the
# lane behaves exactly as today (the dead-lane judgment still runs) instead
# of being routed on a guess.
state="$(new_state)"
write_record "$state" 4202 "{\"issue\":4202,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"gone-agent\",\"pr\":4202,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_API_PR_STATE='' GH_API_STDERR='API rate limit exceeded' GH_API_EXIT=1 run_tick "$state")"
if grep -q "DRY: fleetctl set 4202 status=merging" <<<"$out"; then false; fi
grep -q "DRY: claude -p \[judgment for lane 4202" <<<"$out"
pass "a starved tick leaves the building lane on today's path instead of routing on a guess"

# --- 77. a building lane with an OPEN PR and a finished builder goes to pr-open ----

# Seen live on lane 1987 (2026-08-26 17:54 UTC): the build agent pushed its
# commit and exited cleanly, the pull request was open with checks running
# and auto-merge armed, and the dead-agent judgment parked a healthy lane.
# An open PR means the build produced its output: the lane belongs with the
# pr-open watcher, never with the dead-agent judgment.

# 77a. open PR + absent builder: routed to pr-open; no judgment, no respawn.
state="$(new_state)"
clear_logs
write_record "$state" 4300 "{\"issue\":4300,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4300\",\"pr\":4300,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=OPEN run_tick "$state")"
grep -q "DRY: fleetctl set 4300 status=pr-open" <<<"$out"
grep -q "is open and the build agent has finished" <<<"$out"
pass "a building lane with an open PR and a finished builder is routed to pr-open"
if grep -q "judgment for lane 4300" <<<"$out"; then false; fi
pass "the dead-agent judgment is never asked when the PR is open and the builder is gone"
if grep -q "DRY: herdr agent start" <<<"$out"; then false; fi
pass "no agent is respawned when the open-PR lane is routed to pr-open"

# 77b. a PR closed WITHOUT merging keeps today's path: the dead-lane judgment
# runs, and the lane is neither sent to pr-open nor to merging.
state="$(new_state)"
clear_logs
write_record "$state" 4301 "{\"issue\":4301,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4301\",\"pr\":4301,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=CLOSED run_tick "$state")"
if grep -q "DRY: fleetctl set 4301 status=pr-open" <<<"$out"; then false; fi
if grep -q "DRY: fleetctl set 4301 status=merging" <<<"$out"; then false; fi
grep -q "DRY: claude -p \[judgment for lane 4301" <<<"$out"
pass "a PR closed without merging leaves the building lane on today's judgment path"

# 77c. the builder is still alive and working with its PR already open (a
# relay successor mid-build, say): the lane is left alone, not rerouted.
state="$(new_state)"
clear_logs
write_record "$state" 4302 "{\"issue\":4302,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4302\",\"pr\":4302,\"relays\":0,\"updated_at\":\"$stale_iso\"}"
agents_json='{"result":{"agents":[{"name":"fleet-lane-4302","agent_status":"working","pane_id":"w1:p1"}]}}'
out="$(GH_PR_STATE=OPEN run_tick "$state" HERDR_AGENTS_JSON="$agents_json")"
if grep -q "DRY: fleetctl set 4302 status=pr-open" <<<"$out"; then false; fi
if grep -q "judgment for lane 4302" <<<"$out"; then false; fi
pass "a live working builder with an open PR is never rerouted out from under itself"

# 77d. a builder that relayed out (handoff owed, PR already open) still gets
# its successor: the relay respawn wins over the pr-open routing.
state="$(new_state)"
clear_logs
mkdir -p "$state/briefs"
echo brief > "$state/briefs/brief-4303-build.md"
write_record "$state" 4303 "{\"issue\":4303,\"status\":\"building\",\"tier\":\"routine\",\"agent\":\"fleet-lane-4303\",\"pr\":4303,\"relays\":1,\"worktree\":\"$fake_repo\",\"updated_at\":\"$stale_iso\"}"
out="$(GH_PR_STATE=OPEN run_tick "$state")"
if grep -q "DRY: fleetctl set 4303 status=pr-open" <<<"$out"; then false; fi
grep -q "relay: respawned build agent fleet-lane-4303 to continue after relay 1" <<<"$out"
pass "a relayed-out builder with an open PR still gets its successor instead of a reroute"

# --- 78. the starve alarm names the exhausted budget and when it resets ------------

state="$(new_state)"
write_record "$state" 4400 '{"issue":4400,"status":"pr-open","tier":"routine","pr":440,"relays":0}'
reset_epoch=$(( $(date +%s) + 3600 ))
reset_hhmm="$(date -u -d "@$reset_epoch" +%H:%M)"
rl_json="{\"resources\":{\"core\":{\"remaining\":4900,\"reset\":$reset_epoch},\"graphql\":{\"remaining\":0,\"reset\":$reset_epoch}}}"
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_RATE_LIMIT_JSON="$rl_json" run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer (the GraphQL question budget is used up; it resets at $reset_hhmm UTC); skipping" <<<"$out"
pass "the starve alarm names the GraphQL budget and its reset time"

# 78b. the meter claims both pools are healthy but GraphQL's own count says it
# is empty (live 2026-08-27: the meter under-reported). The self-check wins.

healthy_meter="{\"resources\":{\"core\":{\"remaining\":4900,\"reset\":$reset_epoch},\"graphql\":{\"remaining\":5000,\"reset\":$reset_epoch}}}"
reset_iso="$(date -u -d "@$reset_epoch" +%Y-%m-%dT%H:%M:%SZ)"

state="$(new_state)"
write_record "$state" 4401 '{"issue":4401,"status":"pr-open","tier":"routine","pr":441,"relays":0}'
gql_json="{\"data\":{\"rateLimit\":{\"remaining\":0,\"resetAt\":\"$reset_iso\"}}}"
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_RATE_LIMIT_JSON="$healthy_meter" GH_GQL_RATELIMIT_JSON="$gql_json" run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer (the GraphQL question budget is used up; it resets at $reset_hhmm UTC (GitHub's own meter under-reported this)); skipping" <<<"$out"
pass "GraphQL's own count overrides a meter that under-reports it"

# 78b2. meter and self-check both healthy: the alarm admits it does not know.

state="$(new_state)"
write_record "$state" 4403 '{"issue":4403,"status":"pr-open","tier":"routine","pr":443,"relays":0}'
gql_json="{\"data\":{\"rateLimit\":{\"remaining\":4800,\"resetAt\":\"$reset_iso\"}}}"
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_RATE_LIMIT_JSON="$healthy_meter" GH_GQL_RATELIMIT_JSON="$gql_json" run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer (neither budget looks used up - possibly a secondary limit)" <<<"$out"
pass "the starve alarm admits when neither budget looks used up instead of guessing"

# 78b3. the self-check is itself refused for rate limiting: that refusal is the
# answer, even though it cannot say when the budget comes back.

state="$(new_state)"
write_record "$state" 4404 '{"issue":4404,"status":"pr-open","tier":"routine","pr":444,"relays":0}'
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_RATE_LIMIT_JSON="$healthy_meter" GH_GQL_RATELIMIT_STDERR='API rate limit exceeded' run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer (the GraphQL question budget is used up; it resets at an unknown time (GitHub's own meter under-reported this)); skipping" <<<"$out"
pass "a rate-limited self-check still names the GraphQL budget, without a reset time"

# 78c. the meter probe itself fails: the alarm keeps its older wording.

state="$(new_state)"
write_record "$state" 4402 '{"issue":4402,"status":"pr-open","tier":"routine","pr":442,"relays":0}'
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer (its hourly allowance is exhausted)" <<<"$out"
pass "a failed budget-meter probe falls back to the older alarm wording"

# --- 78d. the all-clear: nothing ever said when GitHub started answering again ----
# The viewer went on showing a GitHub alarm long after the allowance had reset.

# These run live, not dry: the marker file, the allowance file and the
# all-clear are all state the fleet leaves behind, and a dry run is required
# to leave nothing behind (see 79b below), so a dry run cannot exercise them.

# A starved tick leaves a marker behind and sounds no all-clear.
state="$(new_state)"
write_record "$state" 4410 '{"issue":4410,"status":"pr-open","tier":"routine","pr":4410,"relays":0}'
clear_logs
run_tick_live "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' >/dev/null
grep -q "ALARM: GitHub is refusing to answer" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "GitHub is answering again" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
[ -f "$state/.github-starved" ]
pass "a starved tick remembers the starvation for later ticks"

# Still starved: no all-clear, marker stays.
clear_logs
run_tick_live "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' >/dev/null
if grep -q "GitHub is answering again" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
[ -f "$state/.github-starved" ]
pass "a tick that is still starved sounds no all-clear"

# The next tick gets a real answer: one all-clear, in the exact wording the
# viewer watches for, and the marker is cleared.
clear_logs
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' >/dev/null
[ "$(grep -c "log fleet GitHub is answering again; the allowance has reset" "$SHIM_LOG_DIR/fleetctl.log")" = "1" ]
[ ! -f "$state/.github-starved" ]
pass "the first tick GitHub answers again says so once, in the viewer's wording"

# And never again after that.
clear_logs
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' >/dev/null
if grep -q "GitHub is answering again" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "the all-clear is sounded once per recovery, not once per tick"

# A fleet that was never starved never sounds an all-clear.
state="$(new_state)"
write_record "$state" 4411 '{"issue":4411,"status":"pr-open","tier":"routine","pr":4411,"relays":0}'
clear_logs
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' >/dev/null
if grep -q "GitHub is answering again" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
pass "a fleet that was never starved never sounds an all-clear"

# A tick that answers some lanes and then runs out mid-way stays quiet: the
# lower-numbered lane answers, the higher-numbered one is starved.
state="$(new_state)"
write_record "$state" 4412 '{"issue":4412,"status":"pr-open","tier":"routine","pr":4412,"relays":0}'
touch "$state/.github-starved"
clear_logs
run_tick_live "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' >/dev/null
if grep -q "GitHub is answering again" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
[ -f "$state/.github-starved" ]
pass "a tick that runs out of allowance itself never sounds the all-clear"

# A dry run leaves none of it behind: no marker, no all-clear, no reading.
state="$(new_state)"
write_record "$state" 4413 '{"issue":4413,"status":"pr-open","tier":"routine","pr":4413,"relays":0}'
out="$(GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' run_tick "$state")"
grep -q "ALARM: GitHub is refusing to answer" <<<"$out"
[ ! -f "$state/.github-starved" ]
[ ! -f "$state/github-allowance.jsonl" ]
pass "a dry run reports a starved fleet but writes no marker and no reading"

# --- 78e. the allowance trap: every tick records what is left and what it did -----
# The GraphQL pool was found fully drained at 02:49 UTC on 2026-08-27 with no
# record of what drained it.

reading_meter="{\"resources\":{\"core\":{\"remaining\":4900,\"reset\":$reset_epoch},\"graphql\":{\"remaining\":4321,\"reset\":$reset_epoch}}}"

state="$(new_state)"
write_record "$state" 4420 '{"issue":4420,"status":"pr-open","tier":"routine","pr":4420,"relays":0}'
# A board snapshot written just now, plus the real spacing window, keeps
# intake home for this tick, so this is a lanes-only tick and board_read
# must say so. (The harness otherwise forces the spacing to zero.)
echo '[]' > "$state/board-issues.json"
clear_logs
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' GH_RATE_LIMIT_JSON="$reading_meter" >/dev/null
[ "$(wc -l < "$state/github-allowance.jsonl")" = "1" ]
jq -e '.graphql_remaining == 4321 and .core_remaining == 4900 and .lanes == 1 and .board_read == false and .github_answers >= 1 and (.at | length) > 0' \
  "$state/github-allowance.jsonl" >/dev/null
pass "each tick records the GraphQL allowance left and what the tick did"

# The reading is free: the budget meter is asked once per tick and shared with
# the starvation alarm, and no extra pool query is made.
[ "$(grep -c "api rate_limit" "$SHIM_LOG_DIR/gh.log")" = "1" ]
pass "the allowance reading costs one free meter call and nothing from the pools"

# A second tick appends rather than replaces, so a drop between readings is visible.
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' GH_RATE_LIMIT_JSON="$reading_meter" >/dev/null
[ "$(wc -l < "$state/github-allowance.jsonl")" = "2" ]
pass "readings accumulate one line per tick"

# A starved tick takes no reading at all: no extra call while the allowance is gone.
state="$(new_state)"
write_record "$state" 4421 '{"issue":4421,"status":"pr-open","tier":"routine","pr":4421,"relays":0}'
run_tick_live "$state" GH_CHECKS='' GH_CHECKS_STDERR='API rate limit exceeded' GH_RATE_LIMIT_JSON="$reading_meter" >/dev/null
[ ! -f "$state/github-allowance.jsonl" ]
pass "a starved tick records no allowance reading"

# The file is a rolling one, not an unbounded log.
state="$(new_state)"
write_record "$state" 4422 '{"issue":4422,"status":"pr-open","tier":"routine","pr":4422,"relays":0}'
for i in $(seq 1 400); do echo "{\"at\":\"old-$i\"}" >> "$state/github-allowance.jsonl"; done
run_tick_live "$state" GH_API_PR_SHA=deadbeef GH_API_CHECKS='[{"name":"lint","bucket":"pending"}]' GH_RATE_LIMIT_JSON="$reading_meter" >/dev/null
[ "$(wc -l < "$state/github-allowance.jsonl")" = "300" ]
jq -e '.graphql_remaining == 4321' <<<"$(tail -n1 "$state/github-allowance.jsonl")" >/dev/null
pass "the allowance file keeps the last 300 readings and no more"

# A tick that read the board says so, so an 11-page board read can be told
# apart from a tick that only looked at lanes.
state="$(new_state)"
project_json='{"items":[]}'
run_tick_live "$state" GH_PROJECT_JSON="$project_json" GH_RATE_LIMIT_JSON="$reading_meter" >/dev/null
jq -e '.board_read == true and .lanes == 0' "$state/github-allowance.jsonl" >/dev/null
pass "a tick that read the board records that it did"

# --- 79. a spawned agent records which model it is running on -----------------
# The lane record carries the tier, but the tier-to-model mapping is settings
# and can change between ticks, so the record must name the model that
# actually launched.

state="$(new_state)"
clear_logs
write_record "$state" 4501 '{"issue":4501,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick_live "$state" FLEET_BUILD_MODEL=test-model FLEET_BUILD_EFFORT=high FLEET_BUILD_TOOL=claude >/dev/null
grep -q "set 4501 agent_model=test-model agent_effort=high agent_tool=claude" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "log 4501 fleet-lane-4501 is running on the test-model model at high effort, using claude" \
  "$SHIM_LOG_DIR/fleetctl.log"
pass "a spawned agent records the model, effort and tool on its lane record"

# --- 79b. a dry run records nothing ------------------------------------------
# Nothing was launched, so nothing may claim a model is running.

state="$(new_state)"
clear_logs
write_record "$state" 4502 '{"issue":4502,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state" FLEET_BUILD_MODEL=test-model FLEET_BUILD_EFFORT=high)"
grep -q "DRY: herdr agent start fleet-lane-4502" <<<"$out"
if grep -q "agent_model" <<<"$out"; then false; fi
if grep -q "is running on the" <<<"$out"; then false; fi
pass "a dry run starts no agent and records no model"

# --- 80. a branch already checked out somewhere is adopted, not duplicated ----
# Git refuses the same branch in two working copies, so a lane adopted with its
# pull request already open (issue 1883, live 2026-08-27) could never create
# one: it burned both attempts and parked for a human. The existing copy is
# used as it is instead.

state="$(new_state)"
existing_wt="$tmp/existing-1883"
existing_branch="build/1883-vault-mcp-errors"
mkdir -p "$existing_wt"
git -C "$existing_wt" init -q
git -C "$existing_wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$existing_wt" checkout -q -b "$existing_branch"
worktree_list_out="$(printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/%s\n' \
  "$existing_wt" "$existing_branch")"
write_record "$state" 1883 "{\"issue\":1883,\"status\":\"pr-open\",\"tier\":\"routine\",\"pr\":1892,\"branch\":\"$existing_branch\",\"relays\":0}"
out="$(GH_CHECKS='[{"name":"lint","bucket":"pass"}]' run_tick "$state" GIT_WORKTREE_LIST_OUT="$worktree_list_out")"
grep -q "branch $existing_branch is already checked out at $existing_wt; using that working copy instead of making a second one" <<<"$out"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "DRY: fleetctl set 1883 worktree=$existing_wt" <<<"$out"
grep -q "DRY: herdr pane for fleet-qa-1883-r1 .* --cwd $existing_wt" <<<"$out"
pass "a branch already checked out elsewhere is adopted, with no second working copy made"

# The same on the build side: a queued lane whose branch is held by a leftover
# copy takes that copy, and the brief it writes names that path.
state="$(new_state)"
write_record "$state" 1884 "{\"issue\":1884,\"status\":\"queued\",\"tier\":\"routine\",\"relays\":0,\"spec\":\"docs/x.md\",\"branch\":\"$existing_branch\"}"
out="$(run_tick "$state" GIT_SHOWREF_EXIT=0 GIT_WORKTREE_LIST_OUT="$worktree_list_out")"
grep -q "already checked out at $existing_wt" <<<"$out"
if grep -q "worktree add" <<<"$out"; then false; fi
grep -q "DRY: herdr pane for fleet-lane-1884 .* --cwd $existing_wt" <<<"$out"
pass "a queued lane whose branch is already checked out builds in that copy"

# 80b. With nothing holding the branch, a copy is created exactly as before.
state="$(new_state)"
write_record "$state" 1885 '{"issue":1885,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state")"
grep -q "DRY: git .*worktree add -b fleet/lane-1885 .*fleet-lane-1885 origin/main" <<<"$out"
if grep -q "already checked out at" <<<"$out"; then false; fi
pass "with no existing copy of the branch, one is created as before"

# A listing that mentions only OTHER branches is not a match either.
state="$(new_state)"
other_list="$(printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/some/other-branch\n' "$existing_wt")"
write_record "$state" 1886 '{"issue":1886,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state" GIT_WORKTREE_LIST_OUT="$other_list")"
grep -q "DRY: git .*worktree add -b fleet/lane-1886" <<<"$out"
if grep -q "already checked out at" <<<"$out"; then false; fi
pass "a copy holding a different branch does not count as this lane's copy"

# A listing pointing at a path that is gone is stale, not an adoption.
state="$(new_state)"
gone_list="$(printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/fleet/lane-1887\n' "$tmp/no-such-copy")"
write_record "$state" 1887 '{"issue":1887,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
out="$(run_tick "$state" GIT_WORKTREE_LIST_OUT="$gone_list")"
grep -q "DRY: git .*worktree add -b fleet/lane-1887" <<<"$out"
if grep -q "already checked out at" <<<"$out"; then false; fi
pass "a listed path that no longer exists is not adopted"

# 80c. A genuine creation failure still counts an attempt and still parks on
# the second one, unchanged by the adoption check.
state="$(new_state)"
write_record "$state" 1888 '{"issue":1888,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
clear_logs
run_tick_live "$state" GIT_WORKTREE_LIST_OUT="$other_list" \
  GIT_WORKTREE_ADD_EXIT=1 GIT_WORKTREE_ADD_STDERR='fatal: could not create leading directories' >/dev/null
grep -q "worktree creation failed (attempt 1 of 2): fatal: could not create leading directories; will retry next tick" "$SHIM_LOG_DIR/fleetctl.log"
if grep -q "status=blocked" "$SHIM_LOG_DIR/fleetctl.log"; then false; fi
clear_logs
write_record "$state" 1888 '{"issue":1888,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md","worktree_attempts":1}'
run_tick_live "$state" GIT_WORKTREE_LIST_OUT="$other_list" \
  GIT_WORKTREE_ADD_EXIT=1 GIT_WORKTREE_ADD_STDERR='fatal: could not create leading directories' >/dev/null
grep -q "status=blocked" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "worktree creation failed twice in a row; parked with the git error as the reason" "$SHIM_LOG_DIR/fleetctl.log"
pass "a real creation failure still retries once and then parks, unchanged"



# --- 81. a lane whose card left Ready / In progress is let go -----------------
# The board decides what the fleet works on. Intake honours that on the way
# in, but nothing re-checked the card afterwards, so a lane outlived its card
# indefinitely: 13 lanes sat on Backlog cards on 2026-08-27.

board_with() { # <state dir> <issue> <column> -> a board snapshot on disk
  printf '{"items":[{"id":"item_%s","status":"%s","content":{"type":"Issue","number":%s}}]}' "$2" "$3" "$2" \
    > "$1/board-items-full.json"
  # Intake skips its own board read while the last one is recent, so the
  # fixture stays put instead of being overwritten mid-test.
  : > "$1/board-issues.json"
}

state="$(new_state)"
clear_logs
write_record "$state" 5001 '{"issue":5001,"status":"queued","tier":"routine","relays":0,"paused":true}'
board_with "$state" 5001 Backlog
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
[ ! -f "$state/tasks/5001.json" ]
[ -f "$state/tasks-retired/5001.json" ]
grep -q "log 5001 retired: its board card is in Backlog" "$SHIM_LOG_DIR/fleetctl.log"
pass "a queued lane whose card sits in Backlog is retired, paused or not"

# Ready and In progress are left alone.
for column in Ready "In progress"; do
  state="$(new_state)"
  clear_logs
  write_record "$state" 5002 '{"issue":5002,"status":"queued","tier":"routine","relays":0,"paused":true}'
  board_with "$state" 5002 "$column"
  run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
  [ -f "$state/tasks/5002.json" ]
done
pass "a lane whose card is in Ready or In progress is left alone"

# A lane holding work is never let go, whatever its card says.
state="$(new_state)"
clear_logs
write_record "$state" 5003 '{"issue":5003,"status":"queued","tier":"routine","relays":0,"paused":true,"branch":"feat/5003"}'
board_with "$state" 5003 Backlog
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
[ -f "$state/tasks/5003.json" ]
pass "a lane with a branch is never retired, whatever column its card is in"

# A lane that has moved past queued is never let go either.
state="$(new_state)"
clear_logs
write_record "$state" 5004 '{"issue":5004,"status":"qa","tier":"routine","relays":0,"pr":5004}'
board_with "$state" 5004 Backlog
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
[ -f "$state/tasks/5004.json" ]
pass "a lane past queued is never retired, whatever column its card is in"

# An issue with no card at all, and a missing board snapshot, both leave the
# lane alone: the fleet never discards a lane on an answer it does not have.
state="$(new_state)"
clear_logs
write_record "$state" 5005 '{"issue":5005,"status":"queued","tier":"routine","relays":0,"paused":true}'
board_with "$state" 9999 Backlog
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
[ -f "$state/tasks/5005.json" ]
state="$(new_state)"
write_record "$state" 5006 '{"issue":5006,"status":"queued","tier":"routine","relays":0,"paused":true}'
rm -f "$state/board-items-full.json"
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
[ -f "$state/tasks/5006.json" ]
pass "no card, or no board snapshot, leaves the lane alone"

# A dry run retires nothing.
state="$(new_state)"
write_record "$state" 5007 '{"issue":5007,"status":"queued","tier":"routine","relays":0,"paused":true}'
board_with "$state" 5007 Backlog
out="$(run_tick "$state")"
grep -q "DRY: retire lane 5007" <<<"$out"
[ -f "$state/tasks/5007.json" ]
pass "a dry run says which lanes it would retire and retires none"

# --- 82. a lane with no issue link still gets a plan written -------------------
# Older records carry spec="none", which used to stop the lane dead: no link,
# no planning agent, no plan, queued forever. The lane is the issue, so the
# link is derivable from the repo's own remote.

state="$(new_state)"
write_record_without_plan "$state" 530 '{"issue":530,"status":"queued","tier":"routine","relays":0,"spec":"none"}'
out="$(run_tick "$state")"
grep -q "DRY: herdr agent start fleet-spec-530" <<<"$out"
grep -q "example/example" "$state/briefs/brief-530-spec.md"
if grep -q "no spec-writer can be sent" <<<"$out"; then false; fi
pass "a lane with no issue link gets its link from the repo remote and a plan writer sent"

# With no GitHub remote there is genuinely no issue to read, and the lane waits.
state="$(new_state)"
clear_logs
write_record_without_plan "$state" 531 '{"issue":531,"status":"queued","tier":"routine","relays":0,"spec":"none"}'
git -C "$fake_repo" remote remove origin
out="$(run_tick_live "$state" >/dev/null; cat "$SHIM_LOG_DIR/fleetctl.log")"
git -C "$fake_repo" remote add origin https://github.com/example/example.git
grep -q "no GitHub remote to find issue #531 on" <<<"$out"
if grep -q "herdr agent start fleet-spec-531" "$SHIM_LOG_DIR/herdr.log" 2>/dev/null; then false; fi
pass "with no GitHub remote the lane waits instead of guessing an issue link"

# --- 83. a just-spawned agent is not mistaken for a leftover -------------------
# An agent reads its brief before it reports "working". In that gap it looks
# idle, and the leftover sweep closed it: on 2026-08-27 the plan writers for
# issues 819, 906 and 950 were each killed within two minutes of starting, so
# those lanes never got a plan and never moved.

state="$(new_state)"
clear_logs
write_record "$state" 540 '{"issue":540,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
date +%s > "$state/.agent-started-fleet-spec-540"
agents_json='{"result":{"agents":[{"name":"fleet-spec-540","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick_live "$state" HERDR_AGENTS_JSON="$agents_json" >/dev/null; cat "$SHIM_LOG_DIR/fleetctl.log")"
if grep -q "closed the leftover agent window fleet-spec-540" <<<"$out"; then false; fi
if grep -q "pane close" "$SHIM_LOG_DIR/herdr.log"; then false; fi
[ -f "$state/.agent-started-fleet-spec-540" ]
pass "an agent spawned moments ago is left alone instead of being closed as a leftover"

# Past the grace period the same idle agent is a leftover again.
state="$(new_state)"
clear_logs
write_record "$state" 541 '{"issue":541,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
echo "$(( $(date +%s) - 4000 ))" > "$state/.agent-started-fleet-spec-541"
agents_json='{"result":{"agents":[{"name":"fleet-spec-541","agent_status":"idle","pane_id":"w1:p1"}]}}'
out="$(run_tick_live "$state" HERDR_AGENTS_JSON="$agents_json" >/dev/null; cat "$SHIM_LOG_DIR/fleetctl.log")"
grep -q "closed the leftover agent window fleet-spec-541" <<<"$out"
grep -q "pane close w1:p1" "$SHIM_LOG_DIR/herdr.log"
[ ! -f "$state/.agent-started-fleet-spec-541" ]
pass "an idle agent past the grace period is still closed, and its stamp goes with it"

# Every real spawn leaves the stamp behind, so the grace applies to it.
state="$(new_state)"
clear_logs
write_record "$state" 542 '{"issue":542,"status":"queued","tier":"routine","relays":0,"spec":"docs/x.md"}'
run_tick_live "$state" >/dev/null
[ -f "$state/.agent-started-fleet-lane-542" ]
pass "a spawn records when the agent started"

# --- 84. planning a lane shows up on the board ---------------------------------
# The card used to move to In progress only when a builder spawned, so a lane
# having its plan written was invisible on the board (Ben, 2026-08-27).

state="$(new_state)"
clear_logs
write_record_without_plan "$state" 550 '{"issue":550,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/550"}'
board_with "$state" 550 Ready
run_tick_live "$state" FLEET_BOARD_CHECK_SECONDS=3600 >/dev/null
grep -q "agent start fleet-spec-550" "$SHIM_LOG_DIR/herdr.log"
grep -q "item-edit" "$SHIM_LOG_DIR/gh.log"
pass "sending a plan writer moves the issue's card to In progress"

# --- 85. an issue no agent can plan is cut into child issues -------------------
# A tracker issue gets an honest refusal from the planning agent, and the lane
# used to sit queued forever retrying the same refusal daily (1424 and 1559,
# 2026-08-27). Ben's ruling: cut it up and work the pieces.

state="$(new_state)"
clear_logs
write_record_without_plan "$state" 560 '{"issue":560,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/560"}'
# A planning agent already ran this window, half an hour ago, and left no plan.
echo "$(budget_cutoff_epoch_test)" > "$state/.spec-writer-560"
touch -d '40 minutes ago' "$state/.spec-writer-560"
run_tick_live "$state" >/dev/null
grep -q "agent start fleet-slice-560" "$SHIM_LOG_DIR/herdr.log"
if grep -q "agent start fleet-spec-560" "$SHIM_LOG_DIR/herdr.log"; then false; fi
grep -q "set 560 reslice_attempted=1 status=blocked" "$SHIM_LOG_DIR/fleetctl.log"
grep -q "Cut by the fleet daemon from #560" "$state/briefs/brief-560-slice.md"
pass "an issue no agent could plan is handed to a slicing agent, and its lane parks"

# The planning agent is still running: nothing is concluded yet.
state="$(new_state)"
clear_logs
write_record_without_plan "$state" 561 '{"issue":561,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/561"}'
echo "$(budget_cutoff_epoch_test)" > "$state/.spec-writer-561"
touch -d '40 minutes ago' "$state/.spec-writer-561"
agents_json='{"result":{"agents":[{"name":"fleet-spec-561","agent_status":"working","pane_id":"w1:p1"}]}}'
run_tick_live "$state" HERDR_AGENTS_JSON="$agents_json" >/dev/null
if grep -q "agent start fleet-slice-561" "$SHIM_LOG_DIR/herdr.log"; then false; fi
pass "while the planning agent is still working, nothing is cut up"

# A planning agent sent minutes ago has not had time to answer.
state="$(new_state)"
clear_logs
write_record_without_plan "$state" 562 '{"issue":562,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/562"}'
echo "$(budget_cutoff_epoch_test)" > "$state/.spec-writer-562"
run_tick_live "$state" >/dev/null
if grep -q "agent start fleet-slice-562" "$SHIM_LOG_DIR/herdr.log"; then false; fi
pass "a planning agent sent minutes ago is given time before anything is cut up"

# Slicing is tried once per lane, ever.
state="$(new_state)"
clear_logs
write_record_without_plan "$state" 563 '{"issue":563,"status":"queued","tier":"routine","relays":0,"spec":"https://github.com/motioneso/fake/issues/563","reslice_attempted":1}'
echo "$(budget_cutoff_epoch_test)" > "$state/.spec-writer-563"
touch -d '40 minutes ago' "$state/.spec-writer-563"
run_tick_live "$state" >/dev/null
if grep -q "agent start fleet-slice-563" "$SHIM_LOG_DIR/herdr.log"; then false; fi
pass "a lane that was already cut up once is never cut again"

# --- 86. a record with no issue link still finds the plan posted on the issue -------

state="$(new_state)"
write_record_without_plan "$state" 570 '{"issue":570,"status":"queued","tier":"routine","relays":0,"spec":"none"}'
out="$(run_tick "$state" GH_SPEC_COMMENT_COUNT=1)"
grep -q "DRY: herdr agent start fleet-lane-570" <<<"$out"
pass "a lane whose record has no issue link still sees a plan posted on the issue"

# And it is still called plan-less when the issue really has no plan.
state="$(new_state)"
write_record_without_plan "$state" 571 '{"issue":571,"status":"queued","tier":"routine","relays":0,"spec":"none"}'
out="$(run_tick "$state" GH_SPEC_COMMENT_COUNT=0)"
grep -q "written-plan rule: not dispatching" <<<"$out"
pass "a lane with no issue link and no plan is still held at the written-plan gate"

# --- 87. a lane parked for cutting into child issues is left parked ----------------

state="$(new_state)"
clear_logs
cat > "$state/tasks/580.json" <<'JSON'
{"issue":580,"status":"blocked","tier":"routine","relays":0,"qa_rounds":0,
 "spec":"https://github.com/motioneso/fake/issues/580","reslice_attempted":1,
 "blocked_reason":"no agent could plan this as one job, so fleet-slice-580 is cutting it into child issues"}
JSON
out="$(run_tick "$state" 2>&1)"
if grep -qi "deputy" <<<"$out"; then false; fi
pass "a lane being cut into child issues is left parked instead of asked about"

echo "fleet tick tests passed"
