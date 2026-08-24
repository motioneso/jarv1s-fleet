# Fleet launcher

## What this is

The launcher starts the overnight fleet. The viewer shows what each lane is doing without
contacting the project board or the running agents.

For the concise operating instructions, see the [fleet runbook](../../../docs/coordination/fleet-runbook.md).

## Starting it the first time

Install the launcher's separate dependencies once, then start it:

    pnpm --dir scripts/fleet/launcher install --ignore-workspace
    pnpm --dir scripts/fleet/launcher start

The `--ignore-workspace` matters: the launcher sits inside the repo's workspace, so without it
pnpm installs into the repo root and the launcher starts with a missing-package error.

Answer each question, or press Enter to use the value in brackets. The daemon starts in the
background after setup. Closing the viewer does not stop it.

## Setup questions

The first question is which folder holds the project repo the daemon should build in - a git
checkout of the actual product, not this tooling repo. The launcher checks that the folder
exists and has a `.git` folder before it will move on. If you leave it blank it uses the
`JARV1S_REPO` environment variable, or `~/jarv1s-fleet-run` if that is not set either.

The judgment command is the command used when the fleet needs a decision. The three build entries
choose a program, a model and an effort for routine, sensitive, and security work. Enter each as
`program/model/effort`, separated by commas. The program is the agent command to launch, such as
the local Claude CLI or Codex; the model must be one that program accepts, because the fleet
launches the program you name and hands it the model you name. Two parts are read as `model/effort`
and keep the program already set.

To see what is installed and what each program says about the models it takes, run:

    scripts/fleet/models.sh Lane cap limits simultaneous lanes. The start budget limits fresh agents for

the run. The deputy is off by default; when on, it may answer after the wait period. Its safety
limits cannot be changed here.

## Where the agents appear

Lane agents open in their own tab, called Fleet Agents, so they never land in a tab you are working
in. The first agent of a run creates it; later ones split a pane inside it. Set `FLEET_AGENT_TAB` to
use a different name.

## Reading the viewer

In Progress shows active and waiting lanes; each one gets three lines (what it is, a token track,
and one plain sentence on where it stands). Lanes waiting on you collapse to a single dim line.
Ready shows lanes likely to be picked up next. Completed This Run shows only work finished since
the daemon started this run (and, if the run has been ended, no later than that). Use the arrow
keys to move and switch tabs. If the daemon was started at boot rather than by the launcher,
Completed This Run says that the run has no start time and cannot filter safely. Press Enter for
the lane story. Press Escape to return. Press `d` on the list to turn the deputy on or off; its
state is always shown in the header.

The header shows the run clock, whether it is live, lanes in progress against the cap, agent
starts used against tonight's budget, how many lanes are waiting on you, and the deputy's state.
Underneath it, a token total (Claude-run lanes only) shows fresh tokens used and how many came
from cache; a lane run by a different program always says "not reported" there rather than a
number, since there is no transcript to read.

## Choosing which issues a run works

Fleet runs are opt-in: the daemon only picks up board issues that have been put into the run.
Press `i` on the main list to open the picker. It lists the board's task issues sitting in Ready
or In Progress; an issue already in the run says "in this run" at the end of its row. Move with
the arrow keys (or j/k), press `+` to put the highlighted issue into the run, `-` to take it out.
The row updates as soon as GitHub confirms; if GitHub refuses, the reason appears at the bottom
and the mark does not change. Press `r` to reload the list, and Escape or `q` to go back.

## Pause and rescue

Press `p` in a lane to confirm a cooperative pause or resume. The running agent is told what to do,
and the action is recorded. Pausing does not kill an agent.

Press `r` to ask for a rescue preview. Nothing starts until you accept it. Accepting starts one fresh
agent and counts against the run budget. Dismiss leaves the lane unchanged.

## Stopping

Press `q` to close the viewer. The fleet keeps running. To stop the fleet, run:

    systemctl --user disable --now jarv1s-fleet-tick.timer

Press `e` to end the run from inside the viewer instead. After a yes/no confirmation it stops both
the tick timer and the lane watchdog timer, then asks whether to leave any running agents working
or close their panes. Either way it stamps the moment the run ended (so Completed This Run stops
counting from there) and rolls the log over the same way it would at 10 MB. Ending a run does not
close the viewer; press `q` afterwards if you want to leave.

## When something looks wrong at 1am

If the state folder is empty, the daemon has not written its first tick yet. If one row is broken,
the rest of the screen still works; check that lane's record. If the daemon is stopped, press `s`
when offered. A rescue error changes nothing, so try again after checking the command it uses.
