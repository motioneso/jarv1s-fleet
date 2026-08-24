# Jarv1s fleet

Development tooling that runs GitHub issues to completion without a person watching. It is not
part of the product; it drives a checkout of the product from the outside.

## What is here

- `tick.sh` — the daemon. Runs once a minute from a systemd user timer, moves every lane one step,
  and exits. Ticks never overlap.
- `fleetctl.mjs` — reads and writes the lane records.
- `brief-template.md` — the instructions handed to every agent the daemon starts.
- `models.sh` — which program and model runs which kind of work.
- `launcher/` — the terminal screen for starting a run and watching it.
- `tests/` — the daemon's tests, all with the outside world stubbed out.
- `docs/` — the design documents.

## Running it

    pnpm --dir launcher start

Then press `s`. The launcher installs the timer and starts the run.

## Which checkout it works in

The tooling lives here; the code it builds lives somewhere else. Set `JARV1S_REPO` to the product
checkout you want it to work in. It defaults to `~/jarv1s-fleet-run`. The daemon refuses to start
if that path is not a git checkout.

## Where the run's state lives

`~/.local/state/jarv1s-fleet` — one file per lane under `tasks/`, plus the log, the settings, and
the board. Override with `JARV1S_FLEET_STATE`.

## Tests

    pnpm install --ignore-workspace
    pnpm --dir launcher install --ignore-workspace
    pnpm test

Nothing in the tests touches the network, starts a real agent, or writes a real record.
