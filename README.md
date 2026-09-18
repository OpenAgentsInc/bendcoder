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
| `Grep` | Literal search. A file yields `N:line`; a directory is searched recursively and yields `path:N:line`, so a hit can be handed straight to Read or Edit. Binary files are skipped, long lines clipped, and the match count capped so a common pattern cannot swamp the state. |

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

The FFI boundary is string-only — offsets, limits and the `replace_all` flag
travel as text and are parsed in `sys_c.c` — which keeps every law a plain
`String -> ... -> IO(String)`.

---

## The Self-Improvement Loop

`Classify` chooses among `read_code`, `search_code`, `run_build`, `apply_edit`,
`generate_answer` and `task_complete`. `apply_edit` is the loop that lets
Bender change its own code:

```
Classify -> Generate an edit -> Edit applies it -> verify -> pass? keep : roll back -> Classify
```

- **Generate an edit.** The model replies in a sentinel-delimited form
  (`<<<PATH>>>` / `<<<OLD>>>` / `<<<NEW>>>` / `<<<END>>>`) rather than JSON,
  because an edit carries exact source text and sentinels survive the quotes,
  braces and newlines a JSON string has to escape.
- **Verify.** `./run_tests.sh` by default; set `BENDER_VERIFY_CMD` to point the
  loop at a different suite.
- **Roll back.** The file is snapshotted before the edit and restored when
  verification fails, so a bad patch never leaves the tree broken — the failure
  goes back into the state and the next `Classify` round sees it.
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

`BENDER_MAX_STEPS` raises the step ceiling (default 6) for a longer run.

## Bend Constraints (Bend 2.0.5)

- **Affine by default** – `+x` marks a reusable `Data` parameter or match field.
- **Match restrictions** – `match` only inspects parameters and fields, never computed values. A `let` before a `match` on a parameter is rejected.
- **Multi‑scrutinee order** – `match a b:` follows the binder order of `a` then `b`.
- **No forward references** – top‑level mutual recursion is impossible; this enforces totality.
- **Self‑call shrinking** – a recursive call must pass each argument unchanged until one structurally shrinks, and this rule also applies inside `do IO` blocks (e.g., `step(state ++ "x")` is rejected).
- **No `argv`** – use `IO.get_env` for input; the goal arrives via the environment.
- **Qualified constructors** – when pattern‑matching on an imported type, constructors must be qualified, e.g., `case A.ReadCode{}`.
- **FFI law handling** – `law` + `def … import "./file.c"` emits `#define CID_<NAME>` only for laws reachable from `main`; see the `#ifdef` guards in `sys_c.c`.
- **Typed let in `do`** – inside a `do` block a `let` requires an explicit type annotation: `x : String = v`.

These constraints are important for the agent to avoid repeated compilation failures.

```bash
BENDER_MAX_STEPS=8 ./run_bender.sh "Add a greet_bender function to hello.bend, keeping main working."
```

### Tests

```bash
./run_tests.sh
```

Covers the file tools, the agent's edit-block parser and path guard, and checks
that the C runtime compiles and both Bend programs still check and build. This
is also the loop's default verification target.

## Two agents

`bender_agent.c` is the agent `run_bender.sh` builds and runs: it has the full
loop, including `apply_edit` and rollback. `bender_agent.bend` is the same loop
written in Bend, over the primitives in `agent_primitives.bend`:

```bash
bend bender_agent.bend -o bender_loop.c
gcc -std=c11 -O1 -I. bender_loop.c -lpthread -lm -o bender_loop_bin
BENDER_GOAL="Find where the grep match cap is set." ./bender_loop_bin
```

Bend has no `argv` — Base offers only `IO.get_env` — so the Bend loop takes its
goal from `BENDER_GOAL` where `bender_agent.c` takes it from `argv[1]`.

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
- `Generate(model: String, system_prompt: String, prompt: String) -> IO(String)`

### Running the Primitives Pipeline

```bash
./run_agent_primitives.sh
```

---

## API Keys & Configuration

Both keys are git-ignored and can be set in files or environment variables:

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
