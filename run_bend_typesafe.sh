#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# 1. Compile bend program to C code
bend call_typesafe.bend -o call_typesafe.c

# 2. Compile C code to native executable using gcc
gcc -std=c11 -O3 call_typesafe.c -lpthread -lm -o call_typesafe_bin

# 3. Run executable
./call_typesafe_bin
