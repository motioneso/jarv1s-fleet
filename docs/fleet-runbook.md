# Fleet runbook

This is the overnight work queue. The fleet reads the project board, starts work in separate
lanes, waits for checks and review, and records every decision. A dry run proves what the daemon
decides to do; it does not prove that GitHub, the workspace manager, or an agent would complete it.

## Queue tonight's work

Put each issue on project 2, **Issue and Roadmap Work**, with the `task` label and status **Ready**
or **In Progress**. The daemon finds those issues at the start of a tick. It assigns a risk tier,
then records the issue in its own queue. Do not hand-edit the queue files.

To inspect one recorded lane:

    JARV1S_FLEET_STATE=~/.local/state/jarv1s-fleet node ./fleetctl.mjs get ISSUE

Replace `ISSUE` with the issue number.

## Before the first run: two things the fleet needs to actually work

The daemon is a plain user systemd timer. Two things have to be true for it to keep working
after you log out or reboot, and neither shows up as an error until something tries to spawn
an agent and quietly can't:

- **Linger must be enabled**, so the user service keeps running after you log out (and, on
  some setups, across a reboot before you log back in):

      loginctl enable-linger "$USER"

- **The terminal manager (herdr) has to be running.** It is what actually opens a terminal
  and starts an agent in it. If it is down, the fleet still ticks and still parks lanes, but
  nothing can be spawned. Each tick checks this once at the top and writes a single fleet-level
  alarm ("the terminal manager is not reachable") instead of a separate failure for every lane
  that tried to spawn — look for that alarm at the top of the board first if lanes seem stuck
  with no agent running.

## Start the fleet

Install the launcher's separate dependencies once, then start it from the repository directory:

    pnpm --dir launcher install
    pnpm --dir launcher start

The first start asks setup questions and starts the background timer. Later starts reuse the saved
settings. Closing the viewer does not stop the fleet.

Before trusting a new setup, run one safe tick against a throwaway state directory:

    state="$(mktemp -d /tmp/jarv1s-fleet-dry-run-XXXX)"; mkdir -p "$state/tasks"
    FLEET_DRY_RUN=1 JARV1S_FLEET_STATE="$state" ./tick.sh

The output lines beginning `DRY:` are intended actions only.

## Stop the fleet

For an immediate kill switch, create `STOP` in the state directory:

    touch ~/.local/state/jarv1s-fleet/STOP

The timer may remain enabled, but each tick exits without acting. To stop and disable future ticks:

    systemctl --user disable --now jarv1s-fleet-tick.timer

After Ben has checked the queue, remove the kill switch before the next run:

    rm ~/.local/state/jarv1s-fleet/STOP

## Read what it did

The morning summary is the generated board:

    sed -n '1,240p' ~/.local/state/jarv1s-fleet/board.md

The append-only event log has the details:

    tail -n 60 ~/.local/state/jarv1s-fleet/log.jsonl

`blocked` means the lane is parked. Read its reason before acting. `code-complete, unverified`
means a user-facing change still lacks live proof on its pull request. A security lane waits for
Ben's sign-off before merge. A `DEPUTY` entry means the deputy was enabled, waited for the stated
period, and made a reversible decision within its hard safety limits; review those entries first.
