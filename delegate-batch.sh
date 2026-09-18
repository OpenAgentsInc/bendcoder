#!/usr/bin/env bash
# Delegate several issues at once, each in its own git worktree so the agents
# cannot tread on each other.
#
#   ./delegate-batch.sh 34 11 13 19 32
#
# Each issue gets a worktree under ../bender-wt/issue-<n> on its own branch.
# Nothing is committed or merged: the worktrees are left in place with the
# changes in them, and the summary says which ones pass ./run_tests.sh. Review
# and merge deliberately.
#
# run_tests.sh puts every artefact in a per-run temp directory, which is what
# makes running these concurrently safe.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [ $# -eq 0 ]; then
  echo "usage: delegate-batch.sh <issue-number>..."
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash first."
  git status --short
  exit 1
fi

WT_ROOT="$(cd .. && pwd)/bender-wt"
mkdir -p "$WT_ROOT"
BASE="$(git rev-parse --abbrev-ref HEAD)"

run_one() {
  local issue="$1"
  local wt="$WT_ROOT/issue-$issue"
  local branch="devin/issue-$issue"
  local log="/tmp/devin_delegate_$issue.log"

  git worktree remove --force "$wt" >/dev/null 2>&1
  git branch -D "$branch" >/dev/null 2>&1
  git worktree add -q -b "$branch" "$wt" "$BASE" || { echo "#$issue: worktree failed"; return 1; }

  # The API keys are gitignored, so a fresh worktree has none and every
  # Classify or Generate call would fail.
  for f in .env.typesafe .env.openrouter; do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$wt/$f"
  done

  local title body
  title="$(gh issue view "$issue" --json title -q .title)"
  body="$(gh issue view "$issue" --json body -q .body)"

  cat > "/tmp/devin_prompt_$issue.md" <<PROMPTEOF
Work on this issue in the current repository and land the change.

# $title

$body

---

Read README.md first: it documents Bend 2.0.5's constraints, which are not the
ones you will expect. Bend is affine, has no forward references, and its
self-calls must structurally decrease.

Verify with ./run_tests.sh before you finish. Do not commit: the harness
commits for you, so that the branch carries the work and can be merged.
PROMPTEOF

  ( cd "$wt" && timeout 2400 devin -p --prompt-file "/tmp/devin_prompt_$issue.md" \
      --permission-mode dangerous > "$log" 2>&1 )

  local changed tests
  changed="$(cd "$wt" && git status --porcelain | wc -l)"
  if [ "$changed" -eq 0 ]; then
    echo "#$issue: NO CHANGE  ($log)"
    return 0
  fi
  if ( cd "$wt" && ./run_tests.sh > "/tmp/devin_tests_$issue.log" 2>&1 ); then
    tests="PASS"
  else
    tests="FAIL"
  fi

  # Commit on the branch. Without this the work stays uncommitted in the
  # worktree, the branch has no new commits, and `git merge` of it reports
  # "Already up to date" and silently brings nothing across.
  local stat
  stat="$(cd "$wt" && git diff --shortstat HEAD)"
  ( cd "$wt" && git add -A && git commit -q \
      -m "Devin: work on #$issue" \
      -m "Delegated by delegate-batch.sh. Suite result at commit time: $tests." )

  echo "#$issue: $tests  $stat  [branch devin/issue-$issue]"
}

echo "Delegating to Devin in parallel worktrees under $WT_ROOT"
echo "Issues: $*"
echo

for issue in "$@"; do
  run_one "$issue" &
done
wait

echo
echo "================================================================"
echo "  Batch complete. Worktrees are under $WT_ROOT"
echo "================================================================"
echo "Review one with:   git -C $WT_ROOT/issue-<n> diff"
echo "Merge one with:    git merge devin/issue-<n>"
echo "Discard all with:  git worktree remove --force $WT_ROOT/issue-<n>"
