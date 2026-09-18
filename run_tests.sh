#!/usr/bin/env bash
# Verification target for the self-improvement loop: the file tools, the agent's
# own helpers, and that both Bend programs still check and build.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "== tools and agent helpers =="
gcc -std=c11 -O1 -Wall -Wextra -I. test_tools.c -o /tmp/bender_test_tools
/tmp/bender_test_tools

echo
echo "== C runtime compiles =="
gcc -std=c11 -O1 -Wall -Wextra -fsyntax-only bender_agent.c

echo "== hello.bend runs =="
bend hello.bend >/dev/null

# bender_agent.bend uses only some of the laws sys_c.c defines, so this also
# guards the #ifdef CID_* guards in sys_c.c against regressing (issue #5).
echo "== bender_agent.bend checks and builds =="
bend bender_agent.bend -o /tmp/bender_loop.c >/dev/null
gcc -std=c11 -O1 -I. /tmp/bender_loop.c -lpthread -lm -o /tmp/bender_loop_bin

echo
echo "All checks passed."
