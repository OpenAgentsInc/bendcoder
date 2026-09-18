#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# Compile bender_agent.c
gcc -std=c11 -O3 bender_agent.c -lpthread -lm -o bender_agent_bin

# Run Bender Autonomous Agent with interactive terminal UI
./bender_agent_bin
