#!/usr/bin/env bash
# Hand a GitHub issue to Bender and let it work on itself.
#
#   ./delegate.sh 21           # work on issue 21
#   ./delegate.sh 21 12        # ... with a step budget of 12
#
# The tree must be clean before a run, so whatever Bender does is visible as a
# diff and recoverable with `git checkout .`. The agent rolls back any single
# edit that fails verification; this guard is for the case where it leaves the
# tree changed but wrong, which a failing ./run_tests.sh afterwards reveals.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

ISSUE="${1:?usage: delegate.sh <issue-number> [max-steps]}"
STEPS="${2:-12}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash first so Bender's changes are legible."
  git status --short
  exit 1
fi

TITLE="$(gh issue view "$ISSUE" --json title -q .title)"
BODY="$(gh issue view "$ISSUE" --json body -q .body)"
BEFORE="$(git rev-parse HEAD)"

echo "Delegating issue #$ISSUE to Bender: $TITLE"
echo "Step budget: $STEPS"
echo

bend bender_agent.bend -o bender_loop.c
gcc -std=c11 -O1 -I. bender_loop.c -lpthread -lm -o bender_agent_bin

LOG="/tmp/bender_delegate_$ISSUE.log"
BENDER_MAX_STEPS="$STEPS" BENDER_GOAL="$TITLE

$BODY" ./bender_agent_bin 2>&1 | tee "$LOG"

echo
echo "================================================================"
echo "  Result of delegating #$ISSUE (was $BEFORE)"
echo "================================================================"

if [ -z "$(git status --porcelain)" ]; then
  echo "No change. Bender did not land an edit; see $LOG."
  exit 2
fi

git --no-pager diff --stat
echo
if ./run_tests.sh > /tmp/bender_delegate_tests.log 2>&1; then
  echo "run_tests.sh passes. Review the diff, then commit."
else
  echo "run_tests.sh FAILS after Bender's change. Tail of the output:"
  tail -20 /tmp/bender_delegate_tests.log
  echo
  echo "Discard with: git checkout ."
  exit 3
fi
