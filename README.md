# bendcoder

Bendcoder is a new coding agent written in **Bend2**, supplemented with C for network calls, HTTP requests, and systems interfaces missing in Bend2.

## Philosophy: Two Primitives (`Classify` & `Generate`)

Rather than dozens of ad-hoc tools, brittle parsers, and fragile conversational loops, Bendcoder distills agent actions into two core primitives:
1. **`Classify` (System 1 - Fast, Calibrated Decision Making)**:
   - Powered by **TypeSafe System One** (`jev-latest`).
   - Evaluates state against typed questions (`Choice`, `Score`, `Noul`) to yield calibrated routing decisions, confidence, and probabilities in a single batched HTTP call.
2. **`Generate` (System 2 - Generative Synthesis)**:
   - Powered by **OpenRouter** (or any OpenAI-compatible provider like Gemini / Ollama).
   - Produces code synthesis, diff generation, and solutions when `Classify` determines generation is required.

---

## Bend Constraints (Bend 2.0.5)

Every constraint below was verified against Bend 2.0.5 by a failed compile, not
read off the guide — several are not in the guide at all. The section sits this
early on purpose: `do_read_code` serves README lines 1-80 on the first pass, so
this is the context the agent has before it edits Bend.

- **Affine by default** – `+x` marks a reusable `Data` parameter or match field.
- **Match restrictions** – a `match` scrutinizes only parameters and fields, never a computed value. A `let` before a `match` on a parameter is rejected the same way, which is stronger than the error message suggests.
- **Multi‑scrutinee order** – `match a b:` follows binder order.
- **No forward references** – top‑level mutual recursion is impossible; this is the mechanism by which totality is enforced.
- **Self‑call shrinking** – a self-call must pass each argument unchanged until one structurally shrinks, and this holds inside `do IO` too: a `step(state ++ "x")` tail call is rejected identically. An agent loop cannot be written in Bend without a shrinking argument.
- **No `argv`** – Base has `IO.get_env` and nothing else, so a goal arrives through the environment.
- **Qualified constructors** – constructors of an imported type must be qualified in patterns, e.g., `case A.ReadCode{}:`. Not in the guide.
- **FFI law handling** – FFI is `law` + `def … import "./file.c"`, and Bend emits `#define CID_<NAME>` only for laws reachable from `main` — hence the `#ifdef` guards in `sys_c.c` (#5).
- **Typed let in `do`** – inside a `do` block a `let` needs its annotation: `x : String = v`, not `x = v`.
- **No infix `==`/`&&`/`||`** – equality and boolean ops are named functions: `Char.is_eq(c, '_')`, `String.eq(a, b)`, `Nat.eq`, `Bool.and`/`Bool.or`/`Bool.not`. `String.equals` does not exist. This is the single most common syntax error a generative model makes here — a `c == '_'` or `x && y` fails the parse before any type check runs.

---

## Runbook

**Setup.** Bend2 on PATH (`bend --version`; verified against 2.0.5, builds and
runs cleanly on 2.0.9), `gcc`, `curl`. Keys for TypeSafe and OpenRouter either
as `TYPESAFE_API_KEY` / `OPENROUTER_API_KEY` environment variables or as
`.env.typesafe` / `.env.openrouter` files holding the raw key — not
`KEY=value`, so a `KEY=value` secrets file must be sourced into the
environment rather than copied. Both files are git-ignored.

**Run.**

```bash
./run_bendcoder.sh "Report which file defines the grep match cap."
```

`run_bendcoder.sh` compiles `bendcoder_agent.bend` to `bendcoder_agent_bin` and runs it
with `BENDCODER_GOAL` set from its arguments. `BENDCODER_MAX_STEPS` raises the
6-step ceiling; `BENDCODER_VERIFY_CMD` points `apply_edit`'s verification at a
different suite (default `./run_tests.sh`). Run against a clean tree: kept
edits land in the working directory, and a failed verify restores the file —
or removes it outright when the edit is what created it. A run ends
`[TASK COMPLETED]`, `[STALLED]` on a guard trip, or at the step ceiling.

**Verify.**

```bash
./run_tests.sh
```

The same gate every `apply_edit` must pass; run it after any change. No API
keys needed — the suite is fully offline.

**Delegate an issue.**

```bash
./delegate.sh 21 12        # issue 21 to Bendcoder, 12-step budget
./delegate-devin.sh 21     # the same contract via the Devin CLI
./delegate-batch.sh 34 11  # several issues in parallel worktrees
```

`AGENTS.md` is this runbook written for agents working in the repo.

---

## File Tools: `Read`, `Write`, `Edit`

The three tools Bendcoder uses to change code are ported from [`~/coder`](https://github.com/OpenAgentsInc/coder)
(`crates/coder-tools/src/cc/{read,write,edit}.rs`) into plain C in `tools_c.h`,
wrapped by the Bend FFI layer (`sys_c.c`) so there is one implementation
rather than one per caller.

| Tool | Behaviour |
| --- | --- |
| `Read` | 1-indexed lines rendered as `N\tline`, with `offset` and `limit`. Refuses directories, warns on an empty file or an offset past EOF, and caps an unbounded read at 256 KB. |
| `Write` | Full write / overwrite, creating any missing parent directories. Reports whether it created or updated the file. |
| `Edit` | Exact-match `old_string` → `new_string`. An `old_string` matching more than once is refused with the match count unless `replace_all` is set; an empty `old_string` creates a new file. When the exact string is absent, a candidate with Read's `N<tab>` line-number prefix stripped is tried, and used only if it resolves. |
| `Grep` | Literal search. A file yields `N:line`; a directory is searched recursively and yields `path:N:line`, so a hit can be handed straight to Read or Edit. Hits carry a few lines of context, marked `N-line` / `path-N-line` like `grep -C`. Binary files are skipped, long lines clipped, and the match count capped so a common pattern cannot swamp the state. A miss retries case-insensitively; if that finds nothing either, the reply names the longest prefix and suffix of the pattern that do appear and the files holding them, so the next guess starts from something real. |

From Bend (`agent_primitives.bend`):

```python
Read(path: String, offset: U32, limit: U32) -> IO(String)   # limit 0 = to EOF
ReadFile(path: String) -> IO(String)                        # raw, unnumbered
WriteFile(path: String, content: String) -> IO(String)
EditFile(path: String, old_str: String, new_str: String) -> IO(String)
EditFileAll(path: String, old_str: String, new_str: String) -> IO(String)
Grep(pattern: String, path: String) -> IO(String)
Exec(cmd: String) -> IO(String)
```

The FFI boundary is string-only on the way in — offsets, limits and the
`replace_all` flag travel as text and are parsed in `sys_c.c` — and results
come back as plain strings or `Done`/`Fail` results. For `Read`, `sys_c.c`
keeps the IO half (the stat checks, the 256 KB cap, the BOM strip); the split
on `\n`, the offset/limit selection and the `N\tline` rendering are pure and
live in `tool_read.bend`, where the line-count and prefix-strip round-trip are
proved laws rather than examples in `test_tools.c`.

---

## The Self-Improvement Loop

`Classify` chooses among `read_code`, `search_code`, `run_build`, `apply_edit`,
`generate_answer` and `task_complete`. `apply_edit` is the loop that lets
Bendcoder change its own code:

```
Classify -> anchor the edit -> Generate new text -> Edit applies it -> verify -> pass? keep : roll back -> Classify
```

- **Anchor the edit.** The old text is picked out of the file rather than
  transcribed by the model: a generative model asked to reproduce a file's
  bytes verbatim invents text that is not there (#23), and Jev generates
  nothing, so it cannot emit wrong text. `Classify` first picks the file
  from the repository listing — a `Choice` over a closed set, the way
  `read_code`'s picker works — then a `Choice` over the file's line ids,
  where each option's label is a line number and its description the line's
  own text, plus a `Noul` for whether the file holds the thing to change at
  all. A file longer than one page of options gets a window `Choice` first,
  because a `Choice` caps at 255 options. Code then slices the exact bytes
  of the chosen line and its neighbours out of the file it just read —
  widening the window until the slice occurs exactly once — so a fabricated
  `old_string` is impossible rather than refused. The generative model
  writes only `new_string`, the part that is genuinely new.
- **Fall back to the sentinel draft.** When a pick comes back absent,
  unconfident or unusable, the edit drops to the earlier form: the model
  replies in a sentinel-delimited block
  (`<<<PATH>>>` / `<<<OLD>>>` / `<<<NEW>>>` / `<<<END>>>`) rather than JSON,
  because an edit carries exact source text and sentinels survive the quotes,
  braces and newlines a JSON string has to escape. A change spanning files —
  or several spots in one — repeats the `<<<PATH>>>`/`<<<OLD>>>`/`<<<NEW>>>`
  group once per hunk before the single `<<<END>>>`, and the hunks are
  applied and verified as a unit.
- **Verify.** `./run_tests.sh` by default; set `BENDCODER_VERIFY_CMD` to point the
  loop at a different suite. The suite ends by printing a `COVERED: <path>`
  line for every file it exercises; a pass over a file absent from that list is
  reported as "verification passed, but nothing in the suite exercises it",
  not as a clean pass — a green run only says something about the files the
  suite actually reads. A custom verify command can print the same lines to
  take part.
- **Roll back.** The file is snapshotted before the edit lands, and restored
  when verification fails or the edit is refused — a file the edit created is
  removed outright — so a bad patch never leaves the tree broken. The failure
  goes back into the state and the next `Classify` round sees it.
- **Stay in the repo.** Absolute paths and anything containing `..` are refused
  before they reach the tools, and an edit is only drafted against a file the
  loop has already read — a refused edit names the file it needed, which the
  next read serves first.

`read_code` lists the repository on its first pass, then hands that listing to
`Classify` as a `Choice` — which file to read next is a closed set, so it is
selected rather than generated, and no answer can name a file that is not
there. A `none` option lets Jev say no file is worth reading. Each file
carries a cursor, so choosing it again serves the next page rather than the
first one, and a file read to the end drops out of the options. `search_code`
greps the repository for a literal string, which is how the agent finds the
file that matters instead of guessing a name; a pattern is open-ended text,
so it stays with the generation model. Every pattern it runs is recorded with
its outcome: a re-proposed one is skipped rather than grepped again, and a
search that keeps missing is nudged at `read_code`, which can only add
information.

`BENDCODER_MAX_STEPS` raises the step ceiling (default 6) for a longer run.

```bash
BENDCODER_MAX_STEPS=8 ./run_bendcoder.sh "Add a greet_bendcoder function to hello.bend, keeping main working."
```

### Tests

```bash
./run_tests.sh
```

Covers the file tools, the Bend modules' `#|` expectations and laws, and
checks that every Bend program still checks and builds — with warnings as
errors on the repository's own C and on every section of the FFI shims, a
`bash -n` over the scripts, a structural check on the markdown (fences
balanced, no section break splitting an introduction from its block), and
`call_typesafe.bend` compiled. The path guard is also a proof gate:
`guard.bend` ports `path_is_in_repo`, `LAWS.bend` states its refusal rules over
every input, and `PROOF.bend` must fill each one for the suite to pass. This is
also the loop's default verification target, and it reports what it covered;
see the `COVERED:` note under Verify above.

## The agent

`bendcoder_agent.bend` is the agent `run_bendcoder.sh` builds and runs — the whole
loop, including `apply_edit` and rollback. The modules under it:

- `agent_primitives.bend` — `Classify`, `Generate`, the file-tool laws (`P.`)
- `action.bend` — the `Action` type, its parse/show and the round-trip law (`A.`)
- `parse.bend` — the sentinel edit parser, `type Edit`, `type ToolResult` (`E.`)
- `guard.bend` — the path guard; its laws are proved in `LAWS.bend`/`PROOF.bend`
- `reads.bend` — the loop's `Book`: read cursors, the pending read a refused
  edit names, the search-miss and low-confidence runs (`R.`)
- `ui.bend` — colours and rendering (`U.`)
- `selector.bend` — the question set, the thresholds, the route table (`S.`)

What remains in C is only what Bend cannot express: `tools_c.h`'s byte-level
file algorithms wrapped by `sys_c.c`, subprocess `Exec`, the TypeSafe and
OpenRouter HTTP calls (`typesafe_c.c`, `openrouter_c.c`), and the response
JSON extraction (`json_parse_c.c`).

Its `apply_edit` runs the anchor path (file `Choice`, window `Choice`, line
`Choice` plus the presence `Noul`, then exact bytes from the file) and falls
back to drafting one `<<<PATH>>>`/`<<<OLD>>>`/`<<<NEW>>>` group per edit
(a reply carrying more is refused rather than half-applied), verifies with
`BENDCODER_VERIFY_CMD`, and restores the `ReadFile` snapshot with `WriteFile` —
or removes the file outright when the edit is what created it.

Bend has no `argv` — Base offers only `IO.get_env` — so the loop takes its
goal from `BENDCODER_GOAL` and its step ceiling from `BENDCODER_MAX_STEPS`;
`run_bendcoder.sh` maps its arguments onto those.

`selector.bend` is the one reviewable place the question set, the thresholds,
and the answers-to-action table share (design rules 7 and 8): each threshold
carries what it was tuned on, and the table is a `match` over the typed
`LoopAnswers` with its rows pinned by laws.

Bend 2.0.5 shapes that loop in ways worth knowing before editing it:

- **No forward references.** A name must be defined before it is used, so top-level
  mutual recursion is impossible. The loop is therefore one self-recursive
  `agent_step`; handlers return a `Progress` value and never call back into it.
- **Self-calls must structurally decrease.** Arguments are read left to right and
  each must be passed unchanged until one shrinks, which is why `fuel` leads the
  parameter list.
- **A `match` scrutinizes only parameters and fields**, never a computed value, and
  a multi-scrutinee `match a b:` follows binder order. Equality tests are computed
  by the caller and dispatched on as `Bool` parameters.
- **Affine by default.** A value used more than once needs `+` on its parameter or
  match field.

In exchange the loop is total: `Progress` makes "keep going" and "finished"
distinct states, and termination is checked rather than hoped for.

---

## Autonomous Agent Loop & Terminal UI

Bendcoder runs an autonomous decision loop with a live terminal UI:
```
State -> Classify (TypeSafe) -> Calibrated Action -> Tool Execution -> State Update -> Verification
```

### Running the Autonomous Loop

```bash
./run_bendcoder.sh
```

Example run session:
```text
================================================================================
  [BENDCODER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)
================================================================================
[GOAL] Initial Goal: Report which file defines the grep match cap. Do not edit any files.

[INDEX] 37 repository paths injected into the state.
[SNIFF] grep, match
[TOOL SEARCH] Searching for 'grep' ...
   Search for 'grep'
   ...
--------------------------------------------------------------------------------
[STEP 1] Evaluating State with Classify (TypeSafe System One)...
--------------------------------------------------------------------------------
[Classify Decision] search_code (confidence 0.95) (blocked 0.09, progress 0 (confidence 0.99))

[TOOL SEARCH] Searching for 'MAX_MATCH' ...
   tools_c.h-547-// everything else the agent had learned.
   tools_c.h:548:#define BENDCODER_GREP_MAX_MATCHES 200

--------------------------------------------------------------------------------
[STEP 2] Evaluating State with Classify (TypeSafe System One)...
--------------------------------------------------------------------------------
[Classify Decision] task_complete (confidence 0.72) (blocked 0.06, progress 0.9 (confidence 0.8))

[TASK COMPLETED] Bendcoder verified all goals are met!
================================================================================
```

---

## Quickstart: Hello World

### Prerequisites

Ensure you have Bend installed (Bend 2.0+):

```bash
bend --version
```

### Running Hello World

```bash
bend hello.bend
```

Output:
```
Hello, world!
```

---

## Agent Primitives: `Classify` & `Generate`

Defined in `agent_primitives.bend`:
- `Classify(state: State, questions: List<&2, Question>) -> IO(String)`
- `ParseAnswer(json: String, qid: String) -> IO(Answer)`
- `Generate(model: String, system_prompt: String, prompt: String) -> IO(String)`
- `GenerateText(model: String, system_prompt: String, prompt: String) -> IO(String)`

`Classify` returns the raw response; `ParseAnswer` reads one question's object
out of it as a typed `Answer` — `Chosen`, `Scored`, `Nouled`, or `Missing` for
a failed request — which every consumer matches on.

`Classify` sends `state` as a JSON object with named fields — `directive`,
`program`, `observations`, `facts`, `index` and `budget` — rather than one
hand-escaped string of `[label]:` sections, so a question can point at a
field with a backticked path such as `observations` or `index.search_hits`
(design rule 3). `index` is injected retrieval — the repository listing and
the searches already run travel in every payload — because retrieval the
model must ask for is not called. `observations` is the slot #14's
`List<Step>` renders into when it lands; until then the entries are the same
`[label]:` texts the string state carried, bounded per entry and in total
with the oldest dropped on purpose.

### Running the Primitives Pipeline

```bash
./run_agent_primitives.sh
```

---

## API Keys & Configuration

Both keys are git-ignored and can be set in files or environment variables.

### 1. TypeSafe System One (for `Classify`)
- **File:** `.env.typesafe` (template: `.env.typesafe.example`)
- **Env Var:** `TYPESAFE_API_KEY`
- **Standalone cURL test:**
  ```bash
  ./call_typesafe.sh
  ```

### 2. OpenRouter (for `Generate`)
- **File:** `.env.openrouter` (template: `.env.openrouter.example`)
- **Env Var:** `OPENROUTER_API_KEY`
- **Standalone cURL test:**
  ```bash
  ./call_openrouter.sh
  ```
