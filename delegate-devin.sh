#!/usr/bin/env bash
# Hand a GitHub issue to the Devin CLI, the same way delegate.sh hands one to
# Bender. Same contract deliberately: clean tree in, diff and test result out,
# so the two agents' runs are directly comparable on the same issues.
#
#   ./delegate-devin.sh 34
#   ./delegate-devin.sh 34 accept-edits
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

ISSUE="${1:?usage: delegate-devin.sh <issue-number> [permission-mode]}"
MODE="${2:-smart}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash first so the agent's changes are legible."
  git status --short
  exit 1
fi

TITLE="$(gh issue view "$ISSUE" --json title -q .title)"
BODY="$(gh issue view "$ISSUE" --json body -q .body)"

echo "Delegating issue #$ISSUE to Devin: $TITLE"
echo "Permission mode: $MODE"
echo

LOG="/tmp/devin_delegate_$ISSUE.log"
PROMPT_FILE="/tmp/devin_prompt_$ISSUE.md"
cat > "$PROMPT_FILE" <<PROMPTEOF
Work on this issue in the current repository and land the change.

# $TITLE

$BODY

---

Read README.md first: it documents Bend 2.0.5's constraints, which are not the
ones you will expect. Bend is affine, has no forward references, and its
self-calls must structurally decrease.

Verify with ./run_tests.sh before you finish. Do not commit; leave the change
in the working tree.
PROMPTEOF

timeout 1800 devin -p --prompt-file "$PROMPT_FILE" --permission-mode "$MODE" 2>&1 | tee "$LOG"

echo
echo "================================================================"
echo "  Result of delegating #$ISSUE to Devin"
echo "================================================================"

if [ -z "$(git status --porcelain)" ]; then
  echo "No change. Devin did not land an edit; see $LOG."
  exit 2
fi

git --no-pager diff --stat
echo
if ./run_tests.sh > /tmp/devin_delegate_tests.log 2>&1; then
  echo "run_tests.sh passes. Review the diff, then commit."
else
  echo "run_tests.sh FAILS after the change. Tail of the output:"
  tail -20 /tmp/devin_delegate_tests.log
  echo
  echo "Discard with: git checkout ."
  exit 3
fi
