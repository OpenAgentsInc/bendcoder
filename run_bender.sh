#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Compile the Bend agent loop to C, then to a native binary. The emitted C
# carries the FFI shims inline, so the -I. include path is all it needs.
bend bender_agent.bend -o bender_loop.c
gcc -std=c11 -O3 -I. bender_loop.c -lpthread -lm -o bender_agent_bin

# Run Bender Autonomous Agent. Bend has no argv, so the goal travels in
# BENDER_GOAL; BENDER_MAX_STEPS raises the step ceiling for a longer run.
BENDER_GOAL="$*" ./bender_agent_bin
