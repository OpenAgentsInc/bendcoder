# Bendcoder Runbook

Operational guide for agents working in this repository. README.md is the
design document; this file is how to build, run and verify the system.

## What this repo is

Bendcoder is an autonomous coding agent whose loop is written in Bend2
(`bendcoder_agent.bend`) with C FFI shims for what Bend cannot express
(subprocess, HTTPS via curl, `dirent`/`stat`, `mkdir -p`). It edits this
repository against a goal, verifies every edit with a test suite, and rolls
back on failure.

## Prerequisites

- A `bend` executable on PATH (Bend2 CLI). This machine has no `bend` binary;
  the working invocation is `bun ~/work/bend/bend2/main.ts` — put a shim on
  PATH, e.g. a `bend` script that execs it. Verified against 2.0.5; the local
  2.0.9 checkout builds and runs everything cleanly.
- `gcc`, `curl`, `bash`. `gh` only for the delegate scripts.
- API keys (below) for any live run; the suite itself needs none.

## API keys

Two providers: TypeSafe (`Classify`, the decision calls) and OpenRouter
(`Generate`, the text the loop asks for). Each key is read from an environment
variable first, then a file:

| Key | Env var | File |
| --- | --- | --- |
| TypeSafe | `TYPESAFE_API_KEY` | `.env.typesafe` |
| OpenRouter | `OPENROUTER_API_KEY` | `.env.openrouter` |

The `.env.*` files hold the **raw key only** — not `KEY=value`. A secrets file
in `KEY=value` form (e.g. `~/work/.secrets/typesafe.env`) must be sourced into
the environment, not copied:

```bash
set -a && . ~/work/.secrets/typesafe.env && . ~/work/.secrets/openrouter.env && set +a
```

Both files are git-ignored. Never print or commit a key.

Smoke-test either provider before a run:

```bash
./call_typesafe.sh      # curl against the TypeSafe API
./call_openrouter.sh    # curl against OpenRouter
./run_bend_typesafe.sh  # the Bend-side Classify path end to end
```

## Running the agent

```bash
./run_bendcoder.sh "Describe the goal here."
```

This compiles `bendcoder_agent.bend` to `bendcoder_loop.c`, builds
`bendcoder_agent_bin`, and runs it. Bend has no `argv`, so the goal travels in
the environment:

```bash
BENDCODER_GOAL="..." BENDCODER_MAX_STEPS=8 ./bendcoder_agent_bin
```

Environment knobs:

| Variable | Default | Effect |
| --- | --- | --- |
| `BENDCODER_GOAL` | (required) | The objective; `run_bendcoder.sh` maps its args here |
| `BENDCODER_MAX_STEPS` | 6 | Step ceiling; each classify→act round is one step |
| `BENDCODER_VERIFY_CMD` | `./run_tests.sh` | Suite an `apply_edit` must pass to be kept |
| `BENDCODER_CHECK_CMD` | (unset) | Cheap per-file check run before the suite — `<file>` in the command names the changed path (else the path is appended). A failed check rolls the edit back with its error in the state; the suite never runs |
| `BENDCODER_MODEL` | `openai/gpt-oss-120b:nitro` | OpenRouter model for every `GenerateText` call |

The agent edits the working tree it runs in. Run it with a clean tree so its
work is a legible diff; a failed verify restores the file (or removes a file
it created), so a kept-but-wrong change is the only residue to watch for —
`./run_tests.sh` after a run is the check, `git checkout .` the undo.

A run ends `[TASK COMPLETED]` when Jev judges the goal met, `[STALLED]` on a
guard trip (missing key, repeated misses, low-confidence run), or at the step
ceiling.

## Verifying changes

```bash
./run_tests.sh
```

The gate for every edit: C tool tests (`-Wall -Wextra -Werror`), all FFI shim
sections compiled standalone, every `.bend` file's `#|` expectations and
laws, `PROOF.bend`'s path-guard proofs, `bash -n` over the scripts, a
markdown structure check, and the `COVERED:` manifest the edit-verify step
consults. Run it before finishing any change.

## Handing work to the agents

```bash
./delegate.sh 21 12        # issue 21 to Bendcoder itself, 12-step budget
./delegate-devin.sh 21     # the same contract, run by the Devin CLI
./delegate-batch.sh 34 11  # issues in parallel worktrees under ../bendcoder-wt/
```

All three require a clean tree and report the diff plus suite result.
`delegate-batch.sh` copies `.env.typesafe`/`.env.openrouter` into each
worktree because a fresh checkout has none — env-var keys do not need that.

## Layout

- `bendcoder_agent.bend` — the agent loop: dispatch, guards, read/edit handlers
- `agent_primitives.bend` — `Classify`/`Generate`, FFI laws and wrappers (`P.`)
- `selector.bend` — the Jev question set, thresholds, route table (`S.`)
- `action.bend` — the `Action` type (`A.`); `parse.bend` — edit/result parsers (`E.`)
- `reads.bend` — the loop's `Book`: read cursors, pending read, miss/low runs (`R.`)
- `terms.bend` — pure goal-term extraction; `run_agent` greps the survivors into the initial state before step 1 (`T.`)
- `tool_read.bend` — pure read implementation with proved laws
- `guard.bend` / `LAWS.bend` / `PROOF.bend` — the path guard and its proofs
- `tools_c.h` — byte-level file algorithms (Read/Write/Edit/Grep)
- `sys_c.c` — FFI effects incl. `sys.exists`/`sys.remove_file`; `typesafe_c.c`,
  `openrouter_c.c`, `json_parse_c.c` — HTTP and JSON extraction
- `test_tools.c` — the C half of the suite, gated on `tools_c.h`

## Rules of thumb

- Read the "Bend Constraints" section of README.md before writing Bend — the
  affine/`+` markers, no-forward-references, and structural-decrease rules are
  not what other languages teach, and the checker enforces all three.
- Every Bend file ends in `#|` lines the suite diffs against its output;
  update them when behaviour intentionally changes.
- Keep orchestration in Bend, byte-level work in `tools_c.h`, effects in
  `sys_c.c`. That split is the architecture; do not reintroduce a C loop.
- Keys live in env vars or git-ignored `.env.*` files only.
