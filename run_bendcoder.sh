#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Compile the Bend agent loop to C, then to a native binary. The emitted C
# carries the FFI shims inline, so the -I. include path is all it needs.
bend bendcoder_agent.bend -o bendcoder_loop.c
gcc -std=c11 -O3 -I. bendcoder_loop.c -lpthread -lm -o bendcoder_agent_bin

# Run Bendcoder Autonomous Agent. Bend has no argv, so the goal travels in
# BENDCODER_GOAL; BENDCODER_MAX_STEPS raises the step ceiling for a longer run.
BENDCODER_GOAL="$*" ./bendcoder_agent_bin
