#!/usr/bin/env bash
#
# SwiftBar plugin: shows fleet status in the Mac menu bar.
# All the real logic runs on the Linux box; this script just fetches it over
# ssh and prints it. If the fetch fails for any reason, it prints a safe
# fallback menu instead of leaving the menu bar blank or broken.
#
# The "10s" in the file name is how often SwiftBar reruns this script.
# Renaming the file changes the refresh period.

set -u

FLEET_HOST="${FLEET_HOST:-ben@100.64.98.99}"

output="$(ssh -o ConnectTimeout=3 -o BatchMode=yes "$FLEET_HOST" \
  node /home/ben/jarv1s-fleet/menubar/fleet-menu.mjs 2>/dev/null)"
status=$?

if [ "$status" -eq 0 ] && [ -n "$output" ]; then
  printf '%s\n' "$output"
else
  echo "Fleet ?"
  echo "---"
  echo "Cannot reach the fleet box over ssh | color=red"
  echo "Test this in a terminal: ssh $FLEET_HOST true"
fi
