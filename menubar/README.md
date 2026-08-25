# Fleet status in your Mac menu bar

This lets you glance at your Mac's menu bar and see how the fleet is doing:
how many lanes are working, which ones need you, and links to their pull
requests and issues.

## What you need

- A Mac.
- SwiftBar, a free menu bar app. Install it with:

  ```
  brew install swiftbar
  ```

- Your Mac must be able to reach the fleet box over ssh without typing a
  password. If you can already run `ssh ben@100.64.98.99 true` from a
  terminal and it returns with no prompt, you're set. If not, set up an ssh
  key first.

## Install steps

1. Open SwiftBar. The first time it runs, it asks you to pick a folder where
   it will look for plugin scripts. Pick any folder you like, or create a
   new one such as `~/SwiftBar`.
2. Copy `fleet.10s.sh` from this folder into the plugin folder you picked.
3. Make the copied file runnable:

   ```
   chmod +x ~/SwiftBar/fleet.10s.sh
   ```

   (use whatever folder you picked in step 1)
4. In SwiftBar, refresh the plugin list (or just quit and reopen SwiftBar).
   You should see a new item appear in your menu bar showing the fleet's
   status.

## What the menu bar item shows

- A short summary, like `Fleet 2` (2 lanes working) or `Fleet 2 !1` (2
  working, 1 needs you).
- Click it to open a dropdown listing each lane, its status, and links to
  its issue and pull request on GitHub.
- If your Mac can't reach the fleet box, it shows `Fleet ?` along with a
  note telling you the command to run to check the connection yourself.

## Changing the refresh speed

The `10s` in the file name `fleet.10s.sh` tells SwiftBar to refresh every 10
seconds. To change it, rename the file - for example `fleet.30s.sh` for
every 30 seconds, or `fleet.1m.sh` for once a minute. Slower refresh means
less load on the fleet box and less battery use on your Mac.

## If something looks wrong

- If the menu bar item shows `Fleet ?` and says it can't reach the fleet
  box, run the suggested `ssh ... true` command yourself in a terminal and
  see what it says.
- If nothing shows up in the menu bar at all, make sure SwiftBar is running
  and that the plugin file is executable (see step 3 above).
