# Bug: a changed question re-stamps forever and makes Ben's replies invisible

Found 2026-08-25 on live lane 1951. Fixed 2026-08-25: the changed-question branch now retires the stale phone entry, sends a fresh needs-ben, and stamps the clock exactly once.

## What happens

When a parked lane's question changes (the agent made progress and parked again
for a new reason), the phone entry on disk still holds the OLD question.
`ensure_needs_ben` sees the mismatch and refreshes the record's `question` and
`questionAskedAt` -- but never updates or replaces the phone entry, so the
mismatch never goes away and the refresh fires again EVERY tick (44 times on
lane 1951).

Two consequences:

1. Ben never sees the new question -- his phone still shows the old one.
2. Because replies older than `questionAskedAt` are ignored (the staleness rule
   added 2026-08-25, commit aa3f7a0), and the clock refreshes every minute, ANY
   reply Ben sends for that lane is silently ignored, forever. "resume" does
   nothing and nobody says why.

## Where

`tick.sh` `ensure_needs_ben()` (~line 1024): the `if ! grep -qsF -- "$reason"
"$entry"` branch stamps the record but leaves the entry file untouched.

## Fix sketch

When the filed entry does not mention the current reason: retire the old entry
(move it aside so `needs_ben_entry_file` stops finding it), send a fresh
needs-ben with the new question, and stamp `questionAskedAt` once. Next tick
the new entry contains the reason, so nothing re-fires. Retiring must happen
before sending, or both entries match the issue token and the loop continues.

Test: lane parks with question A (entry filed), then re-parks with question B;
second tick must send exactly one new phone entry and stamp once; third tick
must stamp nothing. A reply sent after the single B stamp must count.

## Evidence

- Lane 1951: entry `~/.needs-ben/sent/1787684796716560587.msg` holds the
  tasks-6-8 question; record `question` is the PR-1963 live-path one.
- `grep -c 'set question=needs re-slice: PR 1963' log.jsonl` -> 44.
