#!/usr/bin/env bash
# Manual smoke test for the agent sandbox. Run by hand before ever setting
# FLEET_SANDBOX=1:   scripts/sandbox-smoke.sh [worktree-dir]
# Checks, inside the sandbox: git works, gh is logged in, writing inside the
# work dir succeeds, writing outside it fails.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="$here/scripts/agent-sandbox.sh"
work="${1:-$here}"
work="$(cd "$work" && pwd)"
fail=0

echo "1) git status inside the sandbox:"
if "$wrap" "$work" -- git -C "$work" status --short --branch | head -n 3; then
  echo "   OK"
else
  echo "   FAILED"; fail=1
fi

echo "2) gh login visible inside the sandbox:"
if "$wrap" "$work" -- gh auth status >/dev/null 2>&1; then
  echo "   OK"
else
  echo "   FAILED (gh auth status errored)"; fail=1
fi

echo "3) write inside the work dir:"
if "$wrap" "$work" -- bash -c "touch '$work/.sandbox-smoke' && rm '$work/.sandbox-smoke'"; then
  echo "   OK"
else
  echo "   FAILED"; fail=1
fi

echo "4) write outside the work dir (must be blocked):"
if "$wrap" "$work" -- bash -c "touch '$HOME/.sandbox-smoke-leak'" 2>/dev/null; then
  echo "   FAILED: the sandbox let an agent write outside its folders"
  rm -f "$HOME/.sandbox-smoke-leak"; fail=1
else
  echo "   OK (blocked)"
fi

[ "$fail" = "0" ] && echo "sandbox smoke: all checks passed" || echo "sandbox smoke: FAILURES above"
exit "$fail"
