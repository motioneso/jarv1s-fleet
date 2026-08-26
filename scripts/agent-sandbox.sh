#!/usr/bin/env bash
# agent-sandbox.sh <writable-dir> -- <cmd...>
#
# Runs <cmd> inside a bubblewrap sandbox: the whole filesystem is visible but
# read-only, and writes are allowed ONLY where a lane agent legitimately
# writes:
#   - the lane's working directory (<writable-dir>, usually a git worktree)
#   - the git dir behind that worktree (a worktree's .git is a pointer file
#     into the main repo's .git/worktrees/<name>, so commits need it)
#   - the fleet state dir (records, briefs, log) and needs-ben dir
#   - the agent's own config/cache (~/.claude, ~/.claude.json, ~/.codex,
#     ~/.cache, ~/.config/gh) so logins and session state keep working
#   - /tmp (fresh, private to the sandbox) and /dev/shm
# Network stays ON: agents talk to the model API and GitHub.
#
# Requires unprivileged user namespaces for bwrap. On Ubuntu 24.04 that means
# a one-time AppArmor allowance: sudo install -m 644 scripts/apparmor-bwrap \
#   /etc/apparmor.d/bwrap && sudo apparmor_parser -r /etc/apparmor.d/bwrap
set -euo pipefail

die() { echo "agent-sandbox: $*" >&2; exit 1; }

writable="${1:-}"; shift || true
[ "${1:-}" = "--" ] || die "usage: agent-sandbox.sh <writable-dir> -- <cmd...>"
shift
[ $# -ge 1 ] || die "no command given"
[ -d "$writable" ] || die "writable dir does not exist: $writable"
writable="$(cd "$writable" && pwd)"

STATE_DIR="${JARV1S_FLEET_STATE:-$HOME/.local/state/jarv1s-fleet}"
NEEDS_BEN_DIR="${NEEDS_BEN_DIR:-$HOME/.needs-ben}"

args=(
  --ro-bind / /
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --tmpfs /dev/shm
  --bind "$writable" "$writable"
  --die-with-parent
)

# A git worktree keeps its real git dir inside the main repo: .git here is a
# one-line pointer file "gitdir: <repo>/.git/worktrees/<name>". Commits,
# branches and pushes all write through that, so bind the repo's whole .git
# writable too.
if [ -f "$writable/.git" ]; then
  gitdir="$(sed -n 's/^gitdir: //p' "$writable/.git" | head -n1)"
  case "$gitdir" in /*) ;; *) gitdir="$writable/$gitdir" ;; esac
  common="${gitdir%/worktrees/*}"
  if [ -d "$common" ]; then
    args+=(--bind "$common" "$common")
  fi
fi

for p in \
  "$STATE_DIR" \
  "$NEEDS_BEN_DIR" \
  "$HOME/.claude" \
  "$HOME/.claude.json" \
  "$HOME/.codex" \
  "$HOME/.cache" \
  "$HOME/.config/gh"
do
  [ -e "$p" ] && args+=(--bind "$p" "$p")
done

exec bwrap "${args[@]}" "$@"
