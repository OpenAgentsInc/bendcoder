#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# 1. Compile agent_primitives.bend to C
bend agent_primitives.bend -o agent_primitives.c

# 2. Compile with gcc
gcc -std=c11 -O3 agent_primitives.c -lpthread -lm -o agent_primitives_bin

# 3. Run
./agent_primitives_bin
