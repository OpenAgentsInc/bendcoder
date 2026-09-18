#!/usr/bin/env bash
# Verification target for the self-improvement loop: the file tools and the
# agent's own helpers, plus a check that the Bend side still compiles and runs.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

gcc -std=c11 -O1 -Wall -Wextra -I. test_tools.c -o /tmp/bender_test_tools
/tmp/bender_test_tools

gcc -std=c11 -O1 -fsyntax-only bender_agent.c
bend hello.bend >/dev/null
echo "All checks passed."
