# Where things stand — 2026-08-23, late evening

Read this first, then `README.md` for how to run things and `docs/2026-08-23-fleet-viewer-and-watchdog-design.md`
for the work that is planned but not built.

## What this repo is

Tooling that runs GitHub issues to completion overnight with nobody watching. It is not part of
the product. Ben ruled tonight that it does not need a spec, a review round or a release note to
change - just build it and check the tests still pass.

It moved out of the product repo today, so anything you remember about it living under
`scripts/fleet` is out of date.

## The one thing that proves it works

Tonight the daemon took issue #1422 from a line on the board to merged code with no human
involvement: opened a working folder, started an agent, wrote a plan, built the fix, ran the local
gate, opened pull request 1914, waited out the checks, reviewed its own work properly, and merged.
That is the whole promise of the thing, demonstrated once.

**It has only ever done that once, for one small routine issue.** It has never run several lanes
at once. The memory ceiling and the agent limits have never been tested under real load. Do not
leave five lanes running overnight until the fixes below are in, and watch the first one that does.

## What went wrong tonight, and why it matters most

The lane froze for 57 minutes on a fully green pull request and wrote nothing to its log.

GitHub's hourly allowance for the kind of query the daemon uses ran out - it is shared by every
agent and tool on this machine. When it is exhausted, the command that reads check results prints
a refusal **and still reports success**. The daemon saw no failing checks and no finished checks,
concluded the build was still running, and waited. It recovered on its own when the allowance reset.

This is the worst failure mode the system has, because a frozen lane looks exactly like a working
one. With five lanes overnight, the whole run stops and the morning board still reads "in progress".

Two traps worth carrying beyond this repo:

- A `gh` command can print a rate-limit failure and still exit zero. Never read empty output from
  a successful command as "nothing happened".
- GitHub's two allowances are separate. While one was completely exhausted, the other was
  untouched - `gh api repos/:owner/:repo/commits/<sha>/check-runs` worked fine the whole time.
  Switching to that is the real fix, not better error handling.

## What to build next

`docs/2026-08-23-fleet-viewer-and-watchdog-design.md` has nine units, written and adversarially
reviewed. **Units 1 through 6 must land before the next unattended overnight run.** In order:

1. A tiny production-safety fix. The rule that a user-facing change needs proof it was tried on a
   real instance is satisfied by any comment containing the phrase - including a comment saying the
   proof is *missing*. This is the only way the fleet can break the never-break-prod rule by itself.
2. The freeze described above.
3. Lane limits and how the agent budget is reserved for rescues.
4. Recovery. Today no lane recovers after its first agent stops: agents are told to stop when they
   open the pull request, so when checks go red the daemon asks for a fix and waits forever for a
   push from a session that ended.
5. Stuck checks, and the watchdog that nudges a wedged agent awake.
6. Closing out finished work on GitHub. Tonight pull request 1914 merged and issue #1422 stayed
   open; I closed it by hand.

Ben's rulings already folded in: parked-lane replies act on fixed first words, no model reading his
text; stuck checks get re-run once before parking; limits are 5 lanes and 30 agents; the watchdog
checks whether a process is actually computing before killing anything; three hours is the hard
backstop. None of these are open questions - do not reopen them.

The watchdog is **a shell script on a timer, not a model watching**. Ben rejected the model version
outright: a model watching all night is exactly the cost this daemon exists to avoid.
`~/Jarv1s/scripts/ops/coordinator-watchdog.sh` is the working precedent.

## Loose ends

- **Pull request 1916** in the product repo removes the old copies of everything here. It was armed
  to merge itself with one check still running. Confirm it landed; if it went red, nobody was watching.
- **Issue #1895** in the product repo (proof the launcher works on a live box) is still open.
- The launcher says "Working for" on parked and blocked lanes, where it really means time since the
  lane got stuck. Ben has seen this flagged and not ruled on it.
- Nothing here is tracked as GitHub issues, and there is no longer a process reason to create any.

## Traps that will cost you an hour

- The product checkout the daemon builds in is a **linked git worktree**, so its `.git` is a file,
  not a folder. Testing `[ -d "$dir/.git" ]` rejects it.
- Both `pnpm install` calls need `--ignore-workspace`.
- The working folder `fleet-lane-1319` under `~/jarv1s-fleet-run` is not the fleet's - it holds
  unrelated work. Leave it alone.
- `~/Jarv1s` is shared with other agent sessions. Never `git add -A`, never a bare commit, never
  checkout or stash there. Use a separate worktree.
- `gh pr merge --admin` is blocked by a rule. Use `--squash --auto`.
- Port 1533 is production. Never a test target.

## How Ben wants to be talked to

Plain English, always. He reads status to know whether the work is going well, not to review code.
Name things by what they do, not by what the repo calls them. Keep exact names only where he has to
act on them - a command to run, a file to open. If a sentence has more than one backtick, say it
again without them. **Pass this instruction on to every agent you start.**
