#!/usr/bin/env bash
# Verification target for the self-improvement loop: the file tools, the agent's
# own helpers, and that both Bend programs still check and build.
#
# Every artefact goes in a per-run temp directory, so several checkouts can run
# this at once — which is what delegating a batch of issues to parallel agents
# in separate worktrees does.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bender_tests_XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export BENDER_TEST_DIR="$WORK/scratch"

echo "== tools and agent helpers =="
gcc -std=c11 -O1 -Wall -Wextra -I. test_tools.c -o "$WORK/test_tools"
"$WORK/test_tools"

echo
echo "== C runtime compiles =="
gcc -std=c11 -O1 -Wall -Wextra -fsyntax-only bender_agent.c

# A .bend file's expected stdout lives in the file as `#|` lines — the same
# convention Bend's own gate uses (~/bend/gates/test.ts) — so a change and its
# test fit one hunk in one file, which is the shape the loop's apply_edit can
# produce. Files without `#|` lines are skipped.
echo "== bend expected output (#|) =="
for f in *.bend; do
  grep -q '^#|' "$f" || continue
  want="$(grep '^#|' "$f" | sed 's/^#|//')"
  got="$(bend "$f" 2>"$WORK/$f.err")" || { echo "FAIL: $f"; cat "$WORK/$f.err"; exit 1; }
  [ "$got" = "$want" ] || { echo "FAIL: $f"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true; exit 1; }
  echo "PASS: $f"
done

# The action space's parse/show round-trip is a proved law; checking the
# module is what makes it a gate rather than a comment.
echo "== action.bend proves its laws =="
bend action.bend >/dev/null

# bender_agent.bend uses only some of the laws sys_c.c defines, so this also
# guards the #ifdef CID_* guards in sys_c.c against regressing (issue #5).
echo "== bender_agent.bend checks and builds =="
bend bender_agent.bend -o "$WORK/bender_loop.c" >/dev/null
gcc -std=c11 -O1 -I. "$WORK/bender_loop.c" -lpthread -lm -o "$WORK/bender_loop_bin"

echo
echo "All checks passed."
