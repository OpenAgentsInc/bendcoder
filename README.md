# bendcoder

Bendcoder is an autonomous coding agent written in **Bend2**, supplemented
with C for the pieces Bend cannot express — subprocess, HTTPS, and the rest
of the systems interface. Its loop edits the repository it runs in,
verifies every change against a test suite, and rolls back on failure —
and it is pointed at itself: GitHub issues are handed to the agent as
goals, and it has drafted, applied and verified real upgrades to its own
code. `docs/self-delegation.md` records what that has proven and
`docs/roadmap.md` maps what is still outside its reach (issues #42–#48).

## Philosophy: Two Primitives (`Classify` & `Generate`)

Rather than dozens of ad-hoc tools, brittle parsers, and fragile conversational loops, Bendcoder distills agent actions into two core primitives:
1. **`Classify` (System 1 - Fast, Calibrated Decision Making)**:
   - Powered by **TypeSafe System One** (`jev-latest`).
   - Evaluates state against typed questions (`Choice`, `Score`, `Noul`) to yield calibrated routing decisions, confidence, and probabilities in a single batched HTTP call.
2. **`Generate` (System 2 - Generative Synthesis)**:
   - Powered by **OpenRouter** (or any OpenAI-compatible provider like Gemini / Ollama).
   - Produces code synthesis, diff generation, and solutions when `Classify` determines generation is required.

## How it uses Jev

Jev — TypeSafe's System One model, reached at `api.typesafe.ai` with a
`TYPESAFE_API_KEY` — is the whole decision layer. Once per step, Bend code
packs the loop's structured state (`directive`, `program`, `observations`,
`facts`, `index`, `budget`) into one JSON object and sends it with a map of
typed questions in a single batched call: a `Choice` over the action set
(`read_code`, `search_code`, `apply_edit`, `run_build`, `generate_answer`,
`task_complete`, `none`), `Noul`s like `repeats` and `task_done`, `Score`s
like `risk` and `progress`, and — this is the part that makes edits
unfabricatable — `Choice` questions over closed candidate sets for the
arguments: which file, which window, which line anchor. Jev answers every
question at once, each with a probability and a confidence, in about a
hundred milliseconds; it emits no text, so it can select but never invent.
`selector.bend` then routes those typed answers through its thresholds —
the 0.45 general floor, the 0.65 edit floor, the spent-floor and
retry-edit rules — and code executes exactly the effect that was chosen.

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
different suite (default `./run_tests.sh`); `BENDCODER_CHECK_CMD` adds a cheap
per-file check ahead of it — `<file>` in the command names the changed path,
as in `bend <file> -o /tmp/x.c` — and a failed check rolls the edit back with
its error in the state without paying for the suite; `BENDCODER_MODEL`
overrides the OpenRouter model every `Generate` call uses (default
`openai/gpt-oss-120b:nitro`) — the knob for testing whether a stronger model
moves what the loop can land. `BENDCODER_BASE` names the base.bend the
`index.base_api` digest reads (default: `bend base`, then the usual
`~/bend/bend2` / `~/work/bend/bend2` checkouts). Run against a clean tree: kept edits land in
the working directory, and a failed verify restores the file — or removes it
outright when the edit is what created it. A run ends `[TASK COMPLETED]`,
`[STALLED]` on a guard trip, or at the step ceiling.

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

The issue text becomes the agent's goal; the diff it produced and the suite
result come back for a human to review and commit. `docs/self-delegation.md`
documents the workflow, the failures it has surfaced and the fixes they
earned. `AGENTS.md` is this runbook written for agents working in the repo.

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
| `Edit` | Exact-match `old_string` → `new_string`. An `old_string` matching more than once is refused with the match count unless `replace_all` is set; an empty `old_string` creates a new file. When the exact string is absent, two fallbacks are tried in order — a candidate with Read's `N<tab>` line-number prefix stripped, then `old_string`/`new_string` dedented by their common leading whitespace — and each is used only if it resolves (a model-drafted block routinely arrives indented inside its sentinel markers). |
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

A run starts before the first model call: `git ls-files` is injected into the
state as `index.paths`, base.bend's `def`/`type` signature lines are injected
as `index.base_api` (resolved via `BENDCODER_BASE`, else `bend base`, else
the usual `~/bend/bend2` / `~/work/bend/bend2` checkouts, and filtered to the
namespaces the agent writes against — String, List, Char, Nat, U32, F32,
Bool, Maybe, Result, IO), and the goal's identifier terms — `terms.bend` splits
the goal on non-identifier characters, keeps lowercase words of 3+ chars,
drops a stop list, and takes the first four distinct survivors — are each
grepped once and folded into the state as `[SNIFF]` hits. Retrieval the model
must ask for is not called, so the deterministic retrieval travels in the
state from step 1 rather than costing steps to rediscover. The digest rides
both renderings — `index.base_api` for Classify and a `[Base API]` section in
the Generate prompts — so a draft sees `String.to_lower(s: String) -> String`
where it used to invent `String.equals` (#44).

`Classify` chooses among `read_code`, `search_code`, `run_build`, `apply_edit`,
`generate_answer` and `task_complete` (plus a `none` escape). `apply_edit` is
the loop that lets Bendcoder change its own code:

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
  braces and newlines a JSON string has to escape. One reply is one group —
  a second `<<<PATH>>>` before `<<<END>>>` is a second hunk, which the parser
  refuses rather than half-applies — so a multi-hunk change is a sequence of
  verified edits, not one reply. An empty `<<<OLD>>>` creates the file.
- **Verify.** `./run_tests.sh` by default; set `BENDCODER_VERIFY_CMD` to point the
  loop at a different suite. `BENDCODER_CHECK_CMD` sets a cheaper per-file gate
  that runs first — `<file>` in the command names the changed path — and a
  failed check rolls the edit back with its error in the state, the suite
  never run (#43). The suite ends by printing a `COVERED: <path>`
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
first one, and a file read to the end drops out of the options. Two
consecutive `none` picks is the picker judging the whole remaining list —
reads are exhausted, `read_code` leaves the action options entirely, and a
`read_code` decision routes to `search_code` instead of asking a picker that
already said no. `search_code` greps the repository for a literal string,
which is how the agent finds the file that matters instead of guessing a
name; a pattern is open-ended text, so it stays with the generation model.
Every pattern it runs is recorded with its outcome: a re-proposed one is
skipped rather than grepped again, and a search that keeps missing is nudged
at `read_code`, which can only add information.

### Routing and the Book

`Classify`'s six typed answers are routed by a table in `selector.bend` —
`Act`, `Reread`, `Skip`, `Confirm`, `Stop` — with each threshold recording
what it was tuned on. The rules the route enforces are the loop's memory made
explicit:

- **Confidence floor.** A decision under 0.45 reroutes to reads; `apply_edit`
  clears a higher bar (0.65) because a wrong edit writes to disk. But the
  floor only buys information — two consecutive under-floor reroutes spend
  it, and the next under-floor decision acts through its guarded path.
  `task_complete` is the one exception: a weak "done" is never worth acting
  on.
- **Retry on the error in state.** An `apply_edit` proposed while the last
  verification stands failed is a retry informed by a compiler error the
  state already carries — it acts under the floor rather than rerouting, and
  it is not counted as a flail.
- **Flail halt.** Three consecutive under-floor reroutes stop the run rather
  than burning fuel.
- **Loop guards.** An edit to a file never read reroutes to a read; an answer
  on too little information with nothing read yet reroutes to a read; a
  high-`repeats` action is skipped; top-level `risk` the goal did not ask
  for halts for confirmation.

This bookkeeping travels as a typed `Book` (`reads.bend`) inside the loop's
`Progress` — Bend has no globals, so the per-file read cursors, the pending
read a refused edit names, the search-miss run, the declined-pick run and the
under-floor tally are fields the handlers hand back each step.

### Token accounting

Every `Generate` response is read twice from the same raw payload —
`extract.generation` for the assistant text and `extract.usage` for
`usage.total_tokens` — so one POST yields both. The count accumulates into
`budget.tokens_used` in the state JSON every step, so the model sees the cost
it is burning beside the steps it has left.

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
see the `COVERED:` note under Verify above. Two hard-won properties sit on
top of that: the suite gates on reaching its own final line — a `SUITEPASS`
flag set nowhere else, so a truncated or self-swallowed script exits nonzero
instead of self-certifying — and every non-ignored `.bend`/`.c`/`.h` must
appear in the `COVERED:` manifest, so a new file no check reaches fails the
suite rather than passing untouched.

## What it can do today

Demonstrated on live self-delegations — a human files a GitHub issue,
`delegate.sh` hands the issue text to the agent as its goal with a step
budget, the agent works a clean checkout, and `./run_tests.sh` gates every
edit it lands:

- **Landed autonomously.** Single-file C edits and focused single-site
  changes — issue #38 (`"store":false` on every OpenRouter request) and #39
  (TypeSafe retry parity: the full retryable status set, backoff with
  jitter, the `x-typesafe-retry-count` header) were drafted, applied,
  verified and kept by the agent itself. So were most of the loop-hardening
  fixes the delegation failures exposed.
- **Outside the envelope today.** A novel recursive pure-Bend module — #40
  needed one and ~8 delegated runs each died on a different Bend2 rule, the
  near-miss real but the model not yet able to emit a clean module — and
  wide mechanical field-threading across several files, which is within
  ability per hunk but costs 5–8 steps per edit cycle, so a ~10-site change
  outruns a reasonable delegation budget (#41). Both landed manually.

`docs/self-delegation.md` is the experiment log — every failure observed,
the fix it produced, and the boundary mapped. `docs/roadmap.md` is the
follow-on assessment: the boundaries share one root cause (the loop samples
rather than converging — a failed draft is rolled back and resampled instead
of repaired, and no plan object carries progress between hunks), and the
ordered upgrade path is tracked as issues #42–#48.

## How it compares to frontier coding agents

Bendcoder is a narrow agent measured against a general one — a
Devin/Claude-Code-class tool with a frontier model, arbitrary tools and a
long context. The comparison is worth spelling out because the gap
decomposes cleanly: everything Bendcoder does well is where the design
constrained the model, and everything it does poorly is where it asked a
small model to be a big one.

### Where it is structurally stronger

A few properties are guarantees, not conventions.

- **It cannot fabricate `old_string` on the anchor path.** Jev picks a
  file, a window and a line id from Choices; code slices the exact bytes
  out of the file. A general agent writes `old_string` from memory and
  can produce near-misses that refuse — here the wrong text is
  unrepresentable, not merely refused.
- **Every landed change is verified or gone.** Apply → suite → keep or
  roll back, and the suite cannot self-certify (SUITEPASS,
  coverage-complement). A general agent's edits are verified when it
  chooses to check them; Bendcoder's are verified by construction.
- **Its decisions are calibrated and inspectable.** Every step yields
  typed answers with probabilities, routed by a table whose thresholds
  record what they were measured on. A general agent's confidence is
  prose; Bendcoder's is a number per step.
- **Its loop is a total function.** `agent_step` must structurally
  decrease on `fuel` — termination is checked by the language, backed by
  the flail halt and stall reasons. General agent loops rely on
  heuristics and timeouts.
- **Its memory is small typed data.** The `Book` — read cursors, miss
  runs, declined picks, the under-floor tally — can be read directly to
  see why a step rerouted. A general agent's memory is a context blob.
- **The path guard is proved.** `LAWS.bend`/`PROOF.bend` fill the refusal
  laws — "stays in the repo" is a proof obligation, not a comment.
- **Its failures are loud.** `[STALLED]` with a reason, rolled-back edits
  with the compiler error in the state, a suite that refuses to pass when
  it did not finish. The dangerous agent failure mode — confident, wrong,
  silent — is the one it does not have.

### Where it is weaker

- **The generator is a small model.** `gpt-oss-120b` cannot author a
  ~100-line recursive pure-Bend module even with a correct plan and
  explicit hints (#40 took ~8 failed runs). A frontier model emits that
  module in one shot. Raw capability, not loop design.
- **It samples; it does not repair.** A failed draft is rolled back and
  re-drafted from scratch rather than patched in place (#42).
- **No plan object.** Nothing in the state says "you are 3 of 10 hunks
  through this change," so it re-orients between hunks (#45). A general
  agent carries an explicit task list; Bendcoder's only plan is the
  static issue text.
- **One hunk per edit, the full suite per hunk.** Each `apply_edit` is a
  single group plus a minute-or-more verify; a general agent does a
  10-site refactor in one edit and a targeted check in seconds (#43).
- **The action space is closed.** Six actions; `run_build` is the suite.
  No `git log`, no scratch scripts, no `gh` — a general agent composes
  arbitrary shell, which is most of its debugging power.
- **Its context is bounded.** ~32 KB of observations, oldest dropped;
  nuanced reasoning evaporates where a general agent holds the session.
- **Its grep cannot see the standard library itself.** `index.base_api`
  injects the signature digest (#44), but `P.Grep(".")` still cannot reach
  base.bend's bodies — the names are visible, the implementations are not.
- **No external information and no asking for help.** If the answer is
  not in the repo it does not exist, and a stall is terminal — there is
  no "ask the user" action.
- **Calibration costs steps.** Even when the model knows what to do, a
  0.31 confidence gates it into reroutes; the refused-edit-then-abandon
  failure (#46) is the price of gating on a small model's confidence.

### The honest bottom line

Bendcoder is a real agent — it has autonomously landed verified changes to
itself — but a narrow one: repo-local, verifiable, single-site edits sized
to a small model's generation envelope. A frontier agent is general:
multi-file, long-horizon, arbitrary tools, external information, and a
model that can simply write the code. The roadmap (issues #42–#45) is
precisely "give it the machinery a big-context agent has implicitly" — a
repair loop, cheap checks, a visible stdlib, a plan object — bolted onto a
loop that, unlike a general agent's, can prove things about itself.

## Intersection with Coder

Bendcoder is one member of a family.
[`coder`](https://github.com/OpenAgentsInc/coder) is the closed-source
product — one Rust workspace serving Coder Web, Desktop, Mobile and
Terminal over a worker fleet and a model door — and the `openagents`
monorepo rebuilds it in the open from the same two primitives:
`crates/jev` (the public System One SDK), `crates/coder` (the agent),
`crates/coder-terminal` (the surface). The shared bet is that **Classify
decides, Generate writes, and code owns every effect.** Coder's own
`docs/jev/two-primitives.md` proposes that split as an experiment whose
arm B is "two calls, every effect a program step"; Bendcoder is arm B
already running — self-editing, verified, and measured.

### What the family has that Bendcoder wants

- **The explore program's step shape** (`crates/coder-jev`). One Classify
  request asks every question at once — including the argument Choices
  for branches that do not win — where Bendcoder pays a separate call
  per pick. And a refused action is evidence, not an ending: the step is
  charged, the refusal joins the state, and only the same refusal twice
  with nothing read between ends the run — a cleaner rule for the
  problem Bendcoder's miss/skip counters also track.
- **Recorded exchanges as fixtures** (`coder-jev` `replay`). Every
  Classify call is record/replay, so tests exercise real decision
  sequences with no key. Bendcoder's suite is offline but tests
  mechanics only — recorded exchanges would let it replay live runs
  deterministically.
- **The repo map** (`crates/coder-map`, from the Pierrebhat prototype).
  One embedding per file, cosine top-k, then a Jev Choice over the
  neighbors carrying one-line descriptions — about 200 descriptions fit
  a state file bodies cannot. That is the locate-path upgrade over
  literal grep: a Choice over descriptions ranges over far more of a
  checkout than `index.paths` plus the sniff.
- **The info pack** (`coder.info-pack.v1`). A bounded, cited selection
  of what the loop read, handed to generation once. Bendcoder's bounded
  `observations` is the same idea; the cited-span ranking is the
  refinement that keeps the payload floor low.
- **Gate-with-repair delivery** (Coder's run loop). A run that stops
  with changes gets the gate's failure returned to it, up to two repair
  attempts, then a final gate — and a failure delivers nothing. That is
  issue #42's repair primitive with the termination bound already
  designed.
- **The command-plan loop** (openagents `crates/coder`). Generate
  replies with a JSON plan of `sh -c` commands plus a `why` each; a
  deny list refuses the machine-enders before they spawn; a second
  Classify call judges the round (`pass`/`retry`/`stop`, `useful`,
  `damage`). A freer alternative to the fixed action space — generality
  behind a judgment rather than behind a roster.
- **Trajectory metrics** (ATIF). `waste` groups calls by normalized
  intent and `calls_before_first_change` counts orientation — the
  numbers that would measure Bendcoder's re-orientation cost between
  hunks (#45) directly.

### What Bendcoder contributes back

- **A running arm B.** The proposed architecture exists and its envelope
  is measured: single-file C edits and focused changes land
  autonomously; novel-module authoring and wide threading are the mapped
  boundaries — direct evidence on the experiment's "what would sink it"
  list (the option cap, the state budget, floors, a step with no
  program).
- **The anchored edit.** File Choice → window → line id → exact bytes —
  a fabricated `old_string` is impossible rather than refused, the
  strongest form of "select rather than generate" in the family.
- **A verify gate that cannot self-certify.** SUITEPASS plus the
  coverage complement: a corrupted or truncated suite exits nonzero.
  Found by a delegated run that gutted its own gate.
- **The Book.** Typed loop memory as data — read cursors, the pending
  read a refused edit names, the miss/skip/under-floor runs — the
  explicit side-state a bounded-state selector needs.
- **Floors tuned on live delegations.** The 0.45/0.65 thresholds measured
  on labeled runs, plus the spent-floor and retry-edit rules — the
  calibration evidence the family's eval-first rule asks for.
- **A failure corpus.** Every delegation failure documented with its
  fix in `docs/self-delegation.md` — labeled cases for floor-tuning, and
  the reason the gate now guards itself.

### Suggested next steps

- **For the openagents rebuild:** `crates/coder` today chats and runs
  shell plans — its rebuild plan names `read_file`, `search`,
  `run_build` and `apply_edit` as the next tools. Bendcoder's
  `tools_c.h` semantics are the portable reference: exact-match refusal
  with match counts, the `N\t` strip and dedent fallbacks, grep context
  and miss hints, verify-then-keep-or-restore.
- **For Bendcoder:** the explore program's step shape answers two live
  issues — speculative fan-out folds the per-pick Classify calls into
  one request (cheaper steps), and refusal-as-evidence is a simpler
  read-out rule than the skips counter. The trajectory metrics would
  measure #45's re-orientation cost rather than estimate it.
- **For both:** Bendcoder's delegation corpus is labeled data for the
  family's floor-tuning; Coder's recorded-exchange fixtures are the
  replay mechanism Bendcoder's suite lacks.

## The agent

`bendcoder_agent.bend` is the agent `run_bendcoder.sh` builds and runs — the whole
loop, including `apply_edit` and rollback. The modules under it:

- `agent_primitives.bend` — `Classify`, `Generate`, the file-tool laws (`P.`)
- `action.bend` — the `Action` type, its parse/show and the round-trip law (`A.`)
- `parse.bend` — the sentinel edit parser, `type Edit`, `type ToolResult` (`E.`)
- `guard.bend` — the path guard; its laws are proved in `LAWS.bend`/`PROOF.bend`
- `reads.bend` — the loop's `Book`: read cursors, the pending read a refused
  edit names, the search-miss, low-confidence and declined-pick runs (`R.`)
- `terms.bend` — the goal-term sniff: identifier terms extracted from the
  goal and grepped into the state before step 1 (`T.`)
- `base_api.bend` — the stdlib digest: base.bend's `def`/`type` signature
  lines, joined and namespace-filtered into `index.base_api` (`B.`)
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
`BENDCODER_CHECK_CMD` when set and then `BENDCODER_VERIFY_CMD`, and restores
the `ReadFile` snapshot with `WriteFile` — or removes the file outright when
the edit is what created it.

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
- `GenerateUsage(raw: String) -> IO(Nat)` — `usage.total_tokens` read from
  the same raw response `GenerateText` used, so one POST yields both the
  text and its cost

`Classify` returns the raw response; `ParseAnswer` reads one question's object
out of it as a typed `Answer` — `Chosen`, `Scored`, `Nouled`, or `Missing` for
a failed request — which every consumer matches on.

`Classify` sends `state` as a JSON object with named fields — `directive`
(the goal), `program` (the current step and the actions already run),
`observations` (the bounded log of what tools returned), `facts`
(`changed_paths` and the last `verification` verdict), `index` (injected
retrieval: `paths` is the repository listing, `base_api` the stdlib signature
digest, `search_hits` the searches already run — the sniff's hits land here
too) and `budget` (`steps_left`
and the cumulative `tokens_used`) — rather than one hand-escaped string of
`[label]:` sections, so a question can point at a field with a backticked
path such as `observations` or `index.search_hits` (design rule 3).
`index` exists because retrieval the model must ask for is not called.
`observations` is the slot #14's `List<Step>` renders into when it lands;
until then the entries are the same `[label]:` texts the string state
carried, bounded per entry and in total with the oldest dropped on purpose
— the drop is announced in the list itself.

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
