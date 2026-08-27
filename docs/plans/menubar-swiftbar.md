# Fleet in the Mac menu bar - SwiftBar route

Goal: Ben glances at his Mac menu bar and sees the fleet's health; the dropdown lists
lanes, what is waiting on him, and links to the pull requests and issues. No new app:
SwiftBar (free, brew-installable) renders any script's printed lines as a menu.

## Architecture

All logic lives on the Linux box in this repo. The Mac plugin is a dumb fetch.

- Unit A (Linux): `menubar/fleet-menu.mjs` - a standalone Node script that reads the
  fleet state directory and prints a complete SwiftBar menu as text. Testable here.
- Unit B (Mac): `menubar/fleet.10s.sh` - the SwiftBar plugin. Runs the Unit A command
  over ssh, prints its output verbatim; prints a safe fallback menu when ssh fails.
  Plus `menubar/README.md` - install steps a human follows once.

Contract between the units: `node /home/ben/jarv1s-fleet/menubar/fleet-menu.mjs`
prints a valid SwiftBar menu to stdout, exits 0, in under 1 second, and never crashes -
on any internal error it prints a valid menu whose first row reports the problem in
plain English. It only ever reads; it never writes anything anywhere.

## State directory (read-only input, env `JARV1S_FLEET_STATE`, default
`~/.local/state/jarv1s-fleet`)

- `tasks/*.json` - one record per lane. Fields used: `issue` (number), `title`,
  `status` (one of: queued, building, relaying, qa, qa-green, pr-open, ci-fix,
  merging, blocked, done), `pr` (number or null), `blocked_reason`, `resliced_to`,
  `spec` (GitHub issue URL), `updated_at` (ISO timestamp), `paused` (bool).
- `log.jsonl` - append-only log, one JSON object per line: `ts`, `issue`, `msg`.
  Read only the last ~200 lines (bounded), for ALARM rows from the last hour.
- `run-started` - file whose mtime is the run start (may be absent: no run).
- `.spawn-count` - integer, agent starts used tonight (may be absent: 0).

Special rule carried from the daemon and viewer: a blocked lane is waiting on a
human only after its record has a non-empty `question` field, which is written
when the daemon actually files a question for Ben. Other blocked lanes are
parked for automatic retry or an internal handoff. Re-sliced lanes are also
finished and must stay dim as "split into a follow-up".

## SwiftBar output format (Unit A prints exactly this shape)

```
Fleet 2/10 !1
---
WAITING ON YOU | color=#e5c07b
#1902 needs a database decision | color=#e5c07b href=https://github.com/motioneso/moss/issues/1902
---
#1945 building 12m - Workshop part 1: real build data | color=#00cdcd href=<spec url>
-- PR #1950 | href=<pr url>
#1889 split into a follow-up (issue #1945) | color=gray href=<spec url>
#1943 done - Workshop: asking Moss for a module | color=green href=<spec url>
---
Agent starts 6/10
Run started 21:40 (3h 12m ago)
ALARM fleet code has uncommitted edits (05:28) | color=red
```

Title line rules: `Fleet <active>/<spawn budget used as n/cap is NOT available - use
agent starts used>` is wrong - keep it simpler: `Fleet <working count>` where working
means status not in {done, blocked}; append ` !<n>` only when n lanes have a non-empty
`question` and are not paused. Example: `Fleet 2` or `Fleet 2 !1`. If the state dir is
missing or unreadable: title `Fleet ?` and one menu row explaining what to check.

Menu body rules, in order:
1. If any lanes wait on a human: a yellow WAITING ON YOU section, one row per lane,
   with the reason trimmed to ~70 chars, linked to the lane's GitHub issue.
2. All lanes, most recently updated first: `#<issue> <status word> <age> - <title
   trimmed to ~45>`. Age from `updated_at` like `12m` / `3h`. Colors: working
   statuses #00cdcd, done green, waiting yellow, split/paused gray. If the lane has
   a PR, an indented `-- PR #<n>` sub-row linking to it. Lanes done more than 12
   hours ago are omitted.
3. Footer: agent starts used (from `.spawn-count`), run start age, and any log line
   containing `ALARM` from the last hour (deduplicated, max 3, red).
- Every human-readable string is plain English: no jargon, no coined names, plain
  ASCII punctuation. GitHub URLs: lane issue URL is in `spec`; PR URL is the repo
  part of `spec` with `/pull/<pr>`.

SwiftBar line grammar (all that is needed): text, then optional ` | key=value` params
(`color=`, `href=`, `size=`); `---` separates sections; a leading `--` nests a row
into the row above; the first line before the first `---` is the menu bar title.

## Unit A also ships a test

`menubar/test-menu.sh`: builds a throwaway state dir under /tmp with 4-5 fixture
lane records covering: working lane with PR, lane waiting on a human, re-sliced
lane, fresh done lane, done-yesterday lane (must be omitted); plus a log with one
recent ALARM and one stale ALARM. Runs the script with `JARV1S_FLEET_STATE` pointed
there and greps the output for each rule above (title counts, waiting section, split
lane shown gray and not counted, old done lane absent, stale alarm absent). Exits
non-zero on any miss. Must pass with plain `bash menubar/test-menu.sh`.

## Unit B specifics

- `menubar/fleet.10s.sh`: bash, shebang `#!/usr/bin/env bash`. Host in a variable at
  the top (`FLEET_HOST`, default `ben@100.64.98.99`), overridable by env. Runs
  `ssh -o ConnectTimeout=3 -o BatchMode=yes "$FLEET_HOST" node /home/ben/jarv1s-fleet/menubar/fleet-menu.mjs`
  and prints stdout verbatim. On any failure prints:
  `Fleet ?`, `---`, `Cannot reach the fleet box over ssh | color=red`, and a row
  suggesting the one command to test: `ssh ben@100.64.98.99 true`.
- `menubar/README.md`: install SwiftBar (`brew install swiftbar`), pick a plugin
  folder on first launch, copy `fleet.10s.sh` into it, `chmod +x` it, make sure the
  Mac's ssh key reaches the box without a password prompt. The `10s` in the filename
  is the refresh period; renaming the file changes it. Written for a human reader:
  short, plain English, no jargon.

## Hard rules for builders

- New files only, all inside `menubar/` - never edit any existing tracked file
  (uncommitted edits to tracked files pause the live fleet daemon).
- Read-only toward the state dir; never write into it, never call GitHub, never ssh
  from the Linux side.
- No model names anywhere in any file (a repo test greps for them).
- Do not commit or push - the session coordinator reviews and commits.
- Plain English in every string a human sees; precise technical language is fine in
  code comments.
