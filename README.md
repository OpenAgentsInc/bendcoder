# bender

Bender is a new coding agent written in **Bend2**, supplemented with C for network calls, HTTP requests, and systems interfaces missing in Bend2.

## Philosophy: Two Primitives (`Classify` & `Generate`)

Rather than dozens of ad-hoc tools, brittle parsers, and fragile conversational loops, Bender distills agent actions into two core primitives:
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

---

## File Tools: `Read`, `Write`, `Edit`

The three tools Bender uses to change code are ported from [`~/coder`](https://github.com/OpenAgentsInc/coder)
(`crates/coder-tools/src/cc/{read,write,edit}.rs`) into plain C in `tools_c.h`,
shared by the Bend FFI layer (`sys_c.c`) and the agent runtime (`bender_agent.c`)
so there is one implementation rather than one per caller.

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
Bender change its own code:

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
- **Verify.** `./run_tests.sh` by default; set `BENDER_VERIFY_CMD` to point the
  loop at a different suite. The suite ends by printing a `COVERED: <path>`
  line for every file it exercises; a pass over a file absent from that list is
  reported as "verification passed, but nothing in the suite exercises it",
  not as a clean pass — a green run only says something about the files the
  suite actually reads. A custom verify command can print the same lines to
  take part.
- **Roll back.** Every file the edit touches is snapshotted before its first
  hunk lands, and all are restored when verification fails or a mid-batch
  hunk does — a file the batch created is removed — so a bad patch never
  leaves the tree broken. The failure goes back into the state and the next
  `Classify` round sees it.
- **Stay in the repo.** Absolute paths and anything containing `..` are refused
  before they reach the tools.

`read_code` lists the repository on its first pass, then hands that listing to
`Classify` as a `Choice` — which file to read next is a closed set, so it is
selected rather than generated, and no answer can name a file that is not
there. A `none` option lets Jev say no file is worth reading. Each file
carries a cursor, so choosing it again serves the next page rather than the
first one, and a file read to the end drops out of the options. `search_code`
greps the repository for a literal string, which is how the agent finds the
file that matters instead of guessing a name; a pattern is open-ended text,
so it stays with the generation model.
`read_code` lists the repository on its first pass, then asks the model which
file to read next and serves it with line numbers. Each file carries a cursor,
so naming it again serves the next page rather than the first one, and a reply
that leaks the model's reasoning is mined for a path that actually exists rather
than taken at face value. `search_code` greps the repository for a literal
string, which is how the agent finds the file that matters instead of guessing
a name. Every pattern it runs is recorded with its outcome: the picker is told
which strings were already tried, a re-proposed one is skipped rather than
grepped again, and a search that keeps missing is nudged at `read_code`, which
can only add information.

`BENDER_MAX_STEPS` raises the step ceiling (default 6) for a longer run.

```bash
BENDER_MAX_STEPS=8 ./run_bender.sh "Add a greet_bender function to hello.bend, keeping main working."
```

### Tests

```bash
./run_tests.sh
```

Covers the file tools, the agent's edit-block parser and path guard, and checks
that the C runtime compiles and both Bend programs still check and build —
with warnings as errors on the repository's own C and on every section of the
FFI shims, a `bash -n` over the scripts, a structural check on the markdown
(fences balanced, no section break splitting an introduction from its block),
and `call_typesafe.bend` compiled. The path guard is also a proof gate:
`guard.bend` ports `path_is_in_repo`, `LAWS.bend` states its refusal rules over
every input, and `PROOF.bend` must fill each one for the suite to pass. This is
also the loop's default verification target, and it reports what it covered;
see the `COVERED:` note under Verify above.

## Two agents

`bender_agent.c` is the agent `run_bender.sh` builds and runs: it has the full
loop, including `apply_edit` and rollback. `bender_agent.bend` is the same loop
written in Bend — and only the loop. The modules under it:

- `agent_primitives.bend` — `Classify`, `Generate`, the file-tool laws (`P.`)
- `action.bend` — the `Action` type, its parse/show and the round-trip law (`A.`)
- `parse.bend` — the sentinel edit parser, `type Edit`, `type ToolResult` (`E.`)
- `guard.bend` — the path guard; its laws are proved in `LAWS.bend`/`PROOF.bend`
- `ui.bend` — colours and rendering (`U.`)
- `selector.bend` — the question set, the thresholds, the route table (`S.`)

Its `apply_edit` runs the same anchor path (file `Choice`, window `Choice`, line
`Choice` plus the presence `Noul`, then exact bytes from the file) and falls
back to drafting one `<<<PATH>>>`/`<<<OLD>>>`/`<<<NEW>>>` group per edit
(a reply carrying more is refused rather than half-applied), verifies with
`BENDER_VERIFY_CMD`, and restores the `ReadFile` snapshot with `WriteFile`,
so a file the edit created is left empty rather than removed:

```bash
bend bender_agent.bend -o bender_loop.c
gcc -std=c11 -O1 -I. bender_loop.c -lpthread -lm -o bender_loop_bin
BENDER_GOAL="Find where the grep match cap is set." ./bender_loop_bin
```

Bend has no `argv` — Base offers only `IO.get_env` — so the Bend loop takes its
goal from `BENDER_GOAL` where `bender_agent.c` takes it from `argv[1]`.

`selector.bend` is the one reviewable place the question set, the thresholds,
and the answers-to-action table share (design rules 7 and 8): each threshold
carries what it was tuned on, and the table is a `match` over the typed
`LoopAnswers` with its rows pinned by laws. `bender_agent.c` mirrors it in
`route_decision` and the `BENDER_*_FLOOR` block beside `jev_answer`.

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

Bender runs an autonomous decision loop with a live terminal UI:
```
State -> Classify (TypeSafe) -> Calibrated Action -> Tool Execution -> State Update -> Verification
```

### Running the Autonomous Loop

```bash
./run_bender.sh
```

Example run session:
```text
================================================================================
  🤖 [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)
================================================================================
🎯 [GOAL] Initial Objective: Inspect repository, verify hello.bend, and confirm autonomous capabilities...

--------------------------------------------------------------------------------
📍 [STEP 1] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: read_code (Confidence: 0.82, Probability: 0.87)
📖 [TOOL READ] Reading 'hello.bend'...

--------------------------------------------------------------------------------
📍 [STEP 2] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: run_build (Confidence: 0.98, Probability: 0.98)
⚡ [TOOL EXEC] Running 'bend hello.bend'...
   Output: Hello, world!

--------------------------------------------------------------------------------
📍 [STEP 3] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: task_complete (Confidence: 0.73, Probability: 0.79)
✅ [TASK COMPLETE] Bender confirmed all goals are verified and complete!
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
- `Classify(state: String, questions: List<&2, Question>) -> IO(String)`
- `ParseAnswer(json: String, qid: String) -> IO(Answer)`
- `Generate(model: String, system_prompt: String, prompt: String) -> IO(String)`
- `GenerateText(model: String, system_prompt: String, prompt: String) -> IO(String)`

`Classify` returns the raw response; `ParseAnswer` reads one question's object
out of it as a typed `Answer` — `Chosen`, `Scored`, `Nouled`, or `Missing` for
a failed request — which every consumer matches on.

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
