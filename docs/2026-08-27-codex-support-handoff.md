# Handing the fleet to Codex - 2026-08-27, evening

Written so Codex (or any agent) can pick up support for the fleet without me. Start here, then
`README.md` for how to run things and `docs/fleet-runbook.md` for day-to-day operations.

## How to write, for whoever reads this next

Ben reads status to know whether the work is going well, not to review code. Plain English, every
agent, every time.

- Name things by what they do, not by what the repo calls them. "The daemon can no longer wipe out
  an agent's verdict" beats a sentence full of identifiers.
- Keep exact names only where he must act on something: a command to run, a file to open, an error
  string to search for.
- If a sentence has more than one backtick, say it again without them.
- No invented shorthand. Plain ASCII punctuation - his terminal garbles em-dashes and arrows.
- Commit messages, code comments and specs stay precise and technical. This rule is about chat,
  status updates and handoff docs.
- Pass this instruction on to anyone you delegate to.

## What the fleet is, in one paragraph

Tooling in `/home/ben/jarv1s-fleet` that drives GitHub issues to completion on their own, against a
separate product checkout at `/home/ben/Jarv1s` (the repo `motioneso/moss`). The daemon is
`tick.sh`: a systemd user timer runs it once a minute, it moves every lane one step, then exits.
Ticks never overlap. Each issue being worked is a "lane" with a record in
`~/.local/state/jarv1s-fleet/tasks/<issue>.json`. Records are read and written only through
`fleetctl.mjs`. The board is GitHub Project 2; only the Ready and In progress columns are the
fleet's work, and anything moved off them is retired automatically.

## The safety net you must know about

**The daemon refuses to tick while this checkout has uncommitted changes.** It logs that it skipped
and resumes the moment things are committed. So a half-finished edit does not make the fleet do
something wrong - it makes the fleet stop.

Two consequences for anyone working here:

1. Do your editing in your own worktree, not in `/home/ben/jarv1s-fleet` itself, and leave that
   checkout clean.
2. If the fleet looks frozen, check for uncommitted changes first. `git status --short` in the
   fleet folder. That is the single most likely cause.

## How to test

`pnpm test` from the repo root runs everything: the unit tests, the daemon tests, the watchdog
tests and the launcher self-check. Everything external is faked, so it is safe to run at any time,
including while the fleet is live. It must be green before anything is committed.

Two traps found today:

- If you verify in a separate worktree, do **not** link the dependency folders in from the main
  checkout and then commit. I did, and merging replaced the real dependency folders with links
  pointing at themselves. Fix if it happens again: delete the two links, run `pnpm install` in the
  root and again in `launcher`.
- The daemon tests have two ways of asserting. The dry-run helper checks lines printed to the
  screen beginning with the word DRY. The live helper checks files written by the fake commands.
  Mixing them up produces a confusing "no such file" error. Read the last few tests in
  `tests/test-fleet-tick.sh` before adding one.

## What changed today

Four things landed, all with tests, all on main.

1. **Later pieces of a split issue now wait their turn.** When a big issue is cut into pieces, the
   pieces used to all start at once, and a later piece would find none of the earlier work in the
   repo and give up. The cut can now record a build order, and a lane whose predecessors have not
   finished stays in the queue and says so in plain English.
2. **The daemon can no longer overwrite an agent's verdict.** This was the important one. The
   daemon reads a lane's record at the start of its minute and writes its decision at the end, with
   nothing checking whether the agent changed the record in between. On issue 1586 an agent recorded
   "this is too big to build as one job" and the daemon destroyed that verdict six seconds later,
   and the lane sat stuck for hours. Now every write states what it expects the record to look like
   and is refused if it has moved on; the daemon then leaves that lane for next minute. Codex wrote
   the first version of this; it wrongly applied the check to writes aimed at other issues and
   swallowed output the daemon prints, both since fixed.
3. **Issue 1586 was cut by hand** into 2030, 2031 and 2032, with 1586 itself parked pointing at
   them. 2031 and 2032 are waiting on 2030 through the mechanism in point 1.
4. **Issue 1488 was closed** as work that was already finished: its only child had merged earlier today
   in pull request 2025, and the plan for it says the parent never gets its own pull request.

## Open threads

- **Tracker issues that no agent can plan.** Some issues on the board are roll-ups, not buildable
  work. The fleet now handles the too-big case properly, but a roll-up that should simply be closed
  still burns lanes until a human or a deputy notices. Worth a rule.
- **The GitHub allowance burst.** The hourly query allowance is shared with everything else Ben
  runs, and board writes are the heaviest user. Traced but not solved.
- **Fake data in the development database is fine.** Ben ruled today: only production matters.
  A lane stopped itself over this and did not need to. One side effect is still in place: the
  persistent-runtime chat setting was turned off on Ben's real account in the development database.
  Turn it back on if the app behaves oddly there.

## Where to look when something is wrong

- What the fleet has been doing: `~/.local/state/jarv1s-fleet/log.jsonl`, newest lines at the end.
  Read the tail of it, never the whole file.
- A single lane: `node fleetctl.mjs get <issue>`. Everything on the board: `node fleetctl.mjs list`.
- A weekly scoreboard: `node fleetctl.mjs stats`.
- Writes the record store rejected: `~/.local/state/jarv1s-fleet/fleetctl-errors.log`.
- Agents currently running: `herdr agent list`. Close a stuck one with `herdr pane close <id>`.

## When you are stuck on something only Ben can decide

Do not idle waiting for him, and do not go to him first. Exhaust the agent options, then run
`needs-ben <your-name> "<one-line question>"` and watch `~/.needs-ben/replies/` for the answer.
