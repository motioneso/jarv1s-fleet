# Hand-off: fleet daemon rebuild, ready for review

Written 2026-08-24, for Fable to review. Plain summary first, details after.

## What this is

`jarv1s-fleet` is a small daemon that picks up GitHub issues and drives them to a merged
pull request overnight, without anyone watching it. A one-minute timer runs a script
(`tick.sh`) that looks at each issue's lane, decides what it needs next, and either does
it directly or hands it to a Claude agent. A separate terminal app (`launcher/`) sets it
up and shows a live view of what every lane is doing.

This session carried out a full rebuild against the plan in
`docs/2026-08-23-fleet-viewer-and-watchdog-design.md`, split into nine units. All nine are
built, tested, and committed as of commit `00f8443`. One real end-to-end run has already
happened; details below.

## What changed, in plain terms

1. The daemon now handles GitHub rate limits and notices when it's gone quiet without
   making progress.
2. When a lane needs a fix (failed checks, a stuck review), the daemon sends an agent
   into that lane's own existing work folder with clear instructions, capped at two
   rounds before it gives up and asks a person.
3. Questions the daemon has already asked and answered are remembered, so it doesn't ask
   the same question again while nothing about the situation has changed.
4. When GitHub refuses to merge a pull request automatically, the daemon looks at *why*
   and does the right thing: pulls in the latest main branch if it's behind, sends an
   agent to resolve a real conflict, or stops and asks a person for anything else. Stuck
   merges and stuck checks both have time limits so nothing waits forever.
5. When a pull request merges, the daemon closes its GitHub issue and marks it done on
   the project board itself, rather than leaving that for a person. If GitHub won't
   cooperate, it says so loudly instead of silently giving up.
6. A batch of smaller trust fixes: the daemon no longer confuses issue number 18 with
   1834, or a reply's clock time with issue number 30; a broken command that was
   supposed to make a judgment call now raises a clear alarm instead of guessing; and
   replies to a stuck lane only act on a small set of fixed words, never a model's
   interpretation of free text.
7. A watchdog, running on its own separate timer, watches for an agent that has gone
   quiet. It never stops one just because its pane looks idle — it checks the real
   process underneath first, and only stops an agent once it's confirmed, twice in a
   row, that the process truly isn't doing anything. There's one exception: after three
   hours of total silence, it stops the agent even if it's still burning CPU, in case
   that CPU time is a genuine infinite loop.
8. The live view was rewritten to show honest token totals per lane (never a fake zero
   for agents that don't report usage), and gained a proper way to end a run cleanly —
   stop both timers, decide whether to leave running agents going or shut them down, and
   freeze the "done tonight" count at that point.

## What's been proven for real, and what hasn't

**Proven for real:** one full lane, start to finish, against a real GitHub issue.

- Issue: `motioneso/moss#1422`, "One-shot structured spawns: stable cwd so prompt cache
  can hit"
- The daemon built it, opened `motioneso/moss#1914`, ran review, and merged it
- All seven CI checks on that pull request passed
- The daemon closed the issue itself, with a comment linking back to the merge
- No false alarms, no stuck states, no incorrect actions during the run

**Not yet proven for real:** the watchdog stopping a genuinely stuck agent, and the live
view's end-of-run key, since the one real run that happened finished cleanly before
either was needed. Every other numbered unit above has automated test coverage but has
not yet been watched happening live, beyond this one run.

## How the one real run happened, and why it was stopped

This is worth reading carefully, because it wasn't a clean test.

A live run had been started separately, outside the conversation that did this rebuild
work, with deliberately small limits: at most one lane running at a time, and a budget
of only two fresh agent starts total. It had been ticking, mostly on paused issues, for
several hours before this session's work began, and only actually started working on an
issue partway through.

For part of that run, the version of `tick.sh` it was executing was the one already on
disk in this repo — the same file this session's work was actively rewriting, unit by
unit. So for a period, a real daemon was running against a mid-edit copy of its own
code. Nothing went wrong: only the one lane above ran during that window, it completed
cleanly, and there were no alarms logged. But this was discovered after the fact, not
arranged deliberately, and is exactly the kind of thing worth double-checking rather
than taking on faith.

Once this was noticed, the timer was stopped and disabled
(`systemctl --user disable --now jarv1s-fleet-tick.timer`) before anything else could
run. The other 199 tracked issues were still paused and were never touched.

## What to check, if reviewing this

- The nine units' worth of changes, all in commit `00f8443` on `main`.
- The design doc they follow: `docs/2026-08-23-fleet-viewer-and-watchdog-design.md`,
  including "Ben's rulings, 2026-08-23" near the bottom, which settles several specific
  decisions (the three-hour watchdog backstop, the fixed-word replies, the five-lane and
  thirty-spawn defaults) that shouldn't be second-guessed without a real incident to
  justify revisiting them.
- `.progress-state.md` at the repo root (not committed — a working scratch file) has a
  short plain-English entry per unit, written as each one landed.
- Test commands, all green as of this commit: `bash tests/test-fleet-tick.sh`,
  `bash tests/test-fleet-watchdog.sh`, `pnpm test` (repo root), and
  `pnpm --dir launcher test`.
- The real pull request and issue: `motioneso/moss#1914` and `motioneso/moss#1422`.

## Suggested next step

Before starting another real run: decide on a clean way to run the daemon that doesn't
risk executing code mid-edit again (for example, only starting a real run when the
working tree is clean and committed, which it now is). Then a deliberate, watched real
run — ideally one that exercises the watchdog and the end-of-run key, which are the two
pieces this session couldn't observe for real — would close out the remaining "not yet
proven" gap above.
