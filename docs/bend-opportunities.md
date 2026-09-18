# What Bend buys Bender

A study of the Bend2 language (`~/bend`, Bend 2.0.5) against Bender's current
implementation, aimed at one question: **what does Bend give an autonomous
coding agent that C does not?**

Everything asserted here about the language was checked against Bend 2.0.5 on
this machine, not inferred from the guide. Where a claim was verified by
compiling something, the transcript is described. Citations into the Bend repo
are `absolute/path:line`.

---

## 0. For readers who don't know Bend

Bend is a dependently typed, *affine*, total functional language with
Python-shaped syntax. Four properties matter for an agent:

1. **Totality is mandatory.** Every recursive call must consume a structurally
   smaller argument. A loop that cannot be shown to shrink is a *compile error*,
   not a hang. (`/home/christopherdavid/bend/guide/GUIDE.md:96-118`)
2. **Matches are exhaustive**, and a missing constructor is a compile error.
3. **Values are used at most once** unless marked `+` (reusable, and only for
   `Data`-kinded types). This is what lets the runtime free a matched node on the
   spot with no GC. (`GUIDE.md:169-200`)
4. **Specifications are first-class.** A `law` states a property; a `def` of the
   same name must prove it; `bend PROOF.bend` fails until every law holds.
   (`GUIDE.md:241-299`, and the pattern in
   `/home/christopherdavid/bend/demos/proof_insertion_sort/LAWS.bend:1-20`)

Bend is *not* a systems language. It has no subprocess, no `argv`, no TLS, no
directory listing. Those stay in C. The interesting question is not "can Bender
be all Bend" — it can't — but "which parts of an agent are made materially safer
by moving them".

---

## 1. Ranked summary

Value-to-effort, best first. "One-edit" means Bender could plausibly do it to
itself in a single `<<<OLD>>>`/`<<<NEW>>>` hunk verified by `./run_tests.sh`.

| # | Recommendation | Touches | Effort | One-edit? |
|---|---|---|---|---|
| 1 | [Typed action space (`type Action`)](#r1) — kill the `strcmp` chain | `bender_agent.bend` | small | ✅ best first |
| 2 | [`Exec` returns an exit status](#r2) — the Bend loop currently cannot tell pass from fail | `sys_c.c`, `agent_primitives.bend` | small | ✅ |
| 3 | [`LAWS.bend` + `PROOF.bend` gate](#r3) — make `run_tests.sh` a proof gate | new files, `run_tests.sh` | small | ✅ (2 edits) |
| 4 | [Typed tool results (`type Edit`, `type ToolResult`)](#r4) — no more nullable `char*` triples | new `bender_parse.bend` | small | ✅ |
| 5 | [Move the sentinel parser + path guard into Bend](#r5) — and prove the guard | new `bender_parse.bend`, `bender_agent.bend` | medium | ✅ |
| 6 | [Bend-side `apply_edit` with verify + rollback](#r6) — the self-improvement loop, total | `bender_agent.bend` | medium | after #2 |
| 7 | [De-duplicate the three JSON escapers in C](#r7) | `bender_agent.c` | small | ✅ |
| 8 | [Parallel `Classify` / multi-file read via `IO.fork`](#r8) — measured 3× | `bender_agent.bend` | medium | ✅ |
| 9 | [Adopt Bend's `#|` expected-output test convention](#r9) | every `.bend` file, `run_tests.sh` | small | ✅ |
| 10 | [Transcript as `List<Step>`, not a string blob](#r10) | new `bender_state.bend` | medium | partly |
| 11 | [Split the agent into modules](#r11) | several | small | ✅ |
| 12 | [Stop re-implementing Base](#r12) — `String.trim`, `split`, `lines`, `contains`, `Map` | `bender_parse.bend` | small | ✅ |
| — | [**Don't**: arrays for agent state, GPU `!`, HTTPS in Bend, exec in Bend](#not-worth-doing) | — | — | — |

---

## 2. Verifying the stated constraints

You asked me to check four constraints. **All four are correct.** Here is what
Bend 2.0.5 actually says, plus two more you did not list.

| Constraint | Verdict | Evidence |
|---|---|---|
| Affine by default; `+x` marks a reusable `Data` parameter/field | ✅ correct | `GUIDE.md:169-186`. Writing `after.go` without `+t` on the match field gave `expected: t / observed: t (consumed more than once)` |
| `match` cannot scrutinize a computed value | ✅ correct | `match List.length(U32, xs):` → `a parameter or field scrutinee (a match cannot scrutinize a computed value: give it its own def)` |
| Multi-scrutinee `match a b:` follows binder order | ✅ correct | `match b a:` on `def h(a, b)` → `match scrutinees in binder order`. **Also**: a `let` before a `match` on a parameter is rejected the same way — this is a stronger rule than "binder order" and is worth writing down |
| No forward references | ✅ correct | A `def caller` calling a `def callee` defined below it → `expected: a defined name / observed: callee` |
| Self-calls must structurally decrease | ✅ correct | `def spin(+n: U32) -> U32: spin(n)` → `expected: a decreasing self-call (arguments are read left to right: each passed unchanged until one shrinks)`. **This holds inside `do IO` too**: a `step(state ++ "x")` tail call in an `IO` block is rejected identically. An agent loop in Bend *cannot* be written without a shrinking argument |
| FFI is `law` + `def … import "./file.c"`, with `#define CID_<NAME>` only for laws reachable from `main` | ✅ correct | `GUIDE.md:333-344`; the `#ifdef CID_*` guards in `sys_c.c:30,102,133,173,210` exist for exactly this reason and the comment at `sys_c.c:11-14` documents it |

### Two constraints you did not list, and should

- **There is no `argv`.** Base has `IO.get_env` (`bend2/base.bend:186`) and
  nothing else; `bend2/effs/` contains `get_env.c` but no `args.c`. A Bend
  Bender cannot read `argv[1]` the way `bender_agent.c:569` does. Its goal must
  arrive as `BENDER_GOAL` in the environment. This is a real architectural
  constraint on moving the loop to Bend.
- **Constructors of an imported type must be qualified.** In a file that does
  `import ./action.bend as A`, `case ReadCode{}:` fails with
  `a declared constructor (unknown: ReadCode)`; it must be `case A.ReadCode{}:`.
  Not in the guide; worth a line in the README.

### One nuance on "no forward references"

The constraint is real but the guide's framing is different and more useful:
mutual recursion is banned *because* termination must be checked
(`GUIDE.md:114-118`). The no-forward-reference rule is the *mechanism*. The
practical consequence is the one `bender_agent.bend:67-70` already records: the
loop is one self-recursive `agent_step`, helpers are defined above it and return
values rather than calling back. Every recommendation below respects that.

---

## 3. What Bend uniquely buys an agent

### 3.1 Totality is a real guarantee about the loop

This is the single biggest difference, and it is not theoretical.

`bender_agent.c:588` runs `for (int step = 1; step <= max_steps; step++)`. That
bound is a convention: any future edit that turns it into a `while (!done)` — a
very natural thing for a model to write — compiles fine and can hang forever. An
autonomous agent that edits its own loop is exactly the program where that
matters.

In Bend it is impossible. I tried the natural non-terminating agent loop:

```python
def step(+state: String) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- IO.print(state)
    step(state ++ "x")          # rejected
```

> `expected : a decreasing self-call (arguments are read left to right: each passed unchanged until one shrinks)`

`bender_agent.bend:169` already pays this tax (`fuel: Nat` leads the parameter
list) and gets the guarantee in exchange. **Bender's C loop has no such
guarantee and no way to acquire one.**

The escape hatch is `@unsafe` (`GUIDE.md:116`), and it is not merely
theoretical: Bend's own HTTP server marks its accept loop `@unsafe`
(`/home/christopherdavid/bend/demos/io_http_server/main.bend:41-46`), because a
server genuinely runs forever. So the rule to adopt is not "never `@unsafe`" but
the sharper one: **Bender's agent loop stays fuel-bounded and total; `@unsafe`
appears nowhere in the repo**, and `run_tests.sh` can enforce that with a
`grep`. A fuel bound is the honest model of an agent anyway — `BENDER_MAX_STEPS`
(`bender_agent.c:482-487`) already is one, just unchecked.

Worth knowing that Bend's test suite anticipates the failure mode: the file
`/home/christopherdavid/bend/tests/halt/swapped_induction.bend:1` is labelled
"the AI-loop's classic bad proof" — an induction whose hypothesis swaps its
arguments. The whole `tests/halt/` directory (35 files) is a specification of
which recursion shapes pass, and it is the best reference to hand a model that
is about to write a Bend loop.

### 3.2 Illegal agent states become unrepresentable

Today the agent's decision is a `char*` compared with `strcmp`
(`bender_agent.c:524-541`). Three separate things can go wrong and none is
caught by a compiler: a typo in a criterion name in the JSON payload
(`bender_agent.c:107-111`) silently falls through to the `else` branch; adding a
sixth action means remembering to add a branch; and the parsed edit is three
independent `char*`s that may each be `NULL` (`bender_agent.c:403-414`).

Bend turns all three into compile errors. I confirmed exhaustiveness is
enforced: deleting one `case` from a five-constructor match gives

> `expected : cases for TaskComplete`

**What the affinity discipline costs, calibrated.** Across Bend's 20 eval
programs, about 61% of `def`s carry at least one `+` marker. That is the tax,
and it is mechanical: the error names the variable and points at the second use,
so it is locally fixable every time (I hit it three times writing the sketches
below and each fix was one character). What it buys is more than tidiness —
`/home/christopherdavid/bend/tests/check/negative_data_reuse.bend:14-33` shows
affinity alone killing the classic `omega` non-termination loop, which is what
lets Bend have `Type : Type` with no positivity check
(`GUIDE.md:593-599`). Affine is not linear: using a value *zero* times is always
fine (`tests/check/linear_binder_discard.bend:1-9`), so there is no
"must-consume" obligation to fight.

### 3.3 The agent can prove things about itself

This is the capability with no C analogue at all, and it works *today*. I wrote
Bender's path guard in Bend, stated three laws about it, and Bend proved them —
in 0.14 s:

```python
# guard.bend — the guard itself
def path_ok(+p: String) -> Bool:
  match p:
    case SNil{}:
      False{}
    case SCon{+h, t}:
      Bool.and(
        Bool.not(Bool.or(Char.is_eq(h, '/'), Char.is_eq(h, '~'))),
        Bool.not(String.contains(SCon{h, t}, "..")))
```

```python
# LAWS.bend — the claims. A human writes these; the agent may not touch them.
law no_absolute:
  for rest: String
  {G.path_ok(SCon{Chr{47}, rest}) == False{} : Bool}    # '/' == 47

law no_empty:
  {G.path_ok("") == False{} : Bool}

law no_dotdot_prefix:
  for rest: String
  {G.path_ok(SCon{Chr{46}, SCon{Chr{46}, rest}}) == False{} : Bool}
```

```python
# PROOF.bend — the agent writes these.
def no_absolute(rest): {==}
def no_empty():        {==}

# a lemma: every string starts with the empty string
law starts_empty:
  for s: String
  {True{} == String.starts_with(s, "") : Bool}

def starts_empty(s):
  match s:
    case SNil{}:      {==}
    case SCon{h, t}:  {==}

def no_dotdot_prefix(rest):
  %starts_empty(rest) : {Bool.not(String.contains.if(SCon{'.', rest}, "..", _)) == False{} : Bool}
  {==}
```

Output: `All terms check.`

Two of the three proofs are literally `{==}` — Bend computes the guard on the
symbolic input and sees `False{}` come out. The third needed one four-line
lemma. **This is a proof that Bender's sandbox escape guard cannot be broken by
a whole class of input, and it is re-checked on every build.** `test_tools.c:51-55`
tests five example paths; the law covers all of them and every other path too.

The honest boundary: `IO` is opaque, so you cannot prove "the file on disk is
unchanged". You prove the *pure* part. That is exactly how the Bend repo does
it — `demos/io_http_fetch/LAWS.bend:1-3` says so in as many words: "They pin
`http_body`, its pure part". Bender's pure parts are the path guard, the edit
parser, the action decoder, and the state-clipping rule. All four are where the
bugs actually are.

### 3.4 Real concurrency, and the parallelism that is *not* useful

Bend has two different things people call parallelism, and only one helps an
agent.

**The parallel let `a b = f(x) g(y)` and the GPU `!` call** are for balanced,
pure, divide-and-conquer numeric work — a bitonic sort over a `2^16` tree
(`demos/pure_par_sort/main.bend:5-60`), a quadtree free
(`bend2/base.bend:2744`). The guide is explicit that the scheduler is a
contention-free binary fork-join machine that requires balanced workloads
(`GUIDE.md:141-148`) and that divergent work stays faster on the CPU. Across all
~20 eval programs, the parallel let appears **once**
(`evals/firm.pomodoro_tally.bend:61`). **None of this is a fit for an agent**,
whose work is irregular and IO-bound.

**`IO.fork` / `IO.join` over channels** (`bend2/base.bend:236,246`) is the right
primitive, and it genuinely works. I measured three forked 1000 ms sleeps:

```
done:a done:b done:c
real    0m1.134s
```

Three seconds of latency in 1.13 s of wall clock. Bender's loop is
latency-dominated — one TypeSafe call plus one OpenRouter call per step, both
over the network, serialized today. That is the parallelism worth having, and it
is `IO.fork`, not `!`.

---

## 4. Recommendations

<a id="r1"></a>
### R1. Typed action space — replace the `strcmp` chain with `type Action`

**Effort: small. Best first candidate.**

**What.** Make the agent's five actions a datatype, decode the classifier's
string into it once, and dispatch by `match`.

**Why Bend beats the status quo.** `bender_agent.c:524-541` is an if/else-if
chain over `strcmp` with an implicit `else` meaning "generate_answer". Nothing
connects it to the criteria list in the JSON payload at
`bender_agent.c:107-111`. `bender_agent.bend:137-150` is worse — a
four-`Bool`-parameter cascade whose argument order at the call site
(`bender_agent.bend:158-161`) silently encodes the priority. With a datatype the
compiler enforces that every action is handled, and adding one is a compile
error until it is.

**Sketch** (verified; this compiles and runs on Bend 2.0.5):

```python
type Action is Data:
  ReadCode{}
  RunBuild{}
  ApplyEdit{}
  GenerateAnswer{}
  TaskComplete{}

# Helper first: Bend has no forward references.
def parse_action.of(r: Bool, b: Bool, e: Bool, c: Bool) -> Action:
  match r b e c:
    case True{} _ _ _: ReadCode{}
    case _ True{} _ _: RunBuild{}
    case _ _ True{} _: ApplyEdit{}
    case _ _ _ True{}: TaskComplete{}
    case _ _ _ _:      GenerateAnswer{}

# Unknown text falls to GenerateAnswer, so the function is total: there is no
# "decision string I forgot to handle" path at all.
def parse_action(+s: String) -> Action:
  parse_action.of(
    String.eq(s, "read_code"),
    String.eq(s, "run_build"),
    String.eq(s, "apply_edit"),
    String.eq(s, "task_complete"))

def show_action(a: Action) -> String:
  match a:
    case ReadCode{}:        "read_code"
    case RunBuild{}:        "run_build"
    case ApplyEdit{}:       "apply_edit"
    case GenerateAnswer{}:  "generate_answer"
    case TaskComplete{}:    "task_complete"
```

Note `parse_action` needs no `match` at all — `+s` lets it be compared four
times — which sidesteps the "match only a parameter" rule entirely.

**Bonus, and this is the point.** Once `show_action` exists, the encoder and
decoder can be *proved* consistent. This checks in 0.14 s:

```python
law action_roundtrip:
  for a: A.Action
  {A.parse_action(A.show_action(a)) == a : A.Action}

def action_roundtrip(a):
  match a:
    case A.ReadCode{}:       {==}
    case A.RunBuild{}:       {==}
    case A.ApplyEdit{}:      {==}
    case A.GenerateAnswer{}: {==}
    case A.TaskComplete{}:   {==}
```

**Files.** `bender_agent.bend` (replacing `dispatch_action` at :137 and
`run_action` at :153). Later, `bender_agent.c:524-541` follows.

---

<a id="r2"></a>
### R2. `Exec` must return an exit status

**Effort: small. Unblocks R6.**

**What.** `command.run` (`sys_c.c:34-89`) returns combined stdout+stderr and
throws the exit code away. `Exec` (`agent_primitives.bend:179`) inherits that.
The C runtime has `exec_cmd_status` (`bender_agent.c:32`) and *uses* the status
to decide whether to roll an edit back (`bender_agent.c:446`). **The Bend side
has no way to make that decision.** Any Bend port of the self-improvement loop
is blocked on this.

**Why Bend.** Not a Bend win as such — it is a prerequisite. But the fix should
land as a *typed* result, which is where Bend helps:

```python
# agent_primitives.bend — prefix the output with the exit code and a newline,
# keeping the string-only FFI boundary the rest of the file uses.
law command.run_status:
  String -> IO(String)          # returns "<exit>\n<combined output>"

def command.run_status(cmd):
  import "./sys_c.c"

type Ran is Data:
  Ran{code: U32, output: String}

def Exec2(cmd: String) -> IO(Ran):
  do IO<Ran>:
    raw : String <- command.run_status(cmd)
    return split_code(raw)     # helper defined above; Maybe-free, total
```

`sys_c.c` needs a new `#ifdef CID_COMMAND_RUN_STATUS` block that captures
`WEXITSTATUS(pclose(...))` and prepends it. Keep the `#ifdef` guard: without it
any program not reaching this law fails to compile (`sys_c.c:11-14`).

**Files.** `sys_c.c`, `agent_primitives.bend`.

---

<a id="r3"></a>
### R3. A `LAWS.bend` / `PROOF.bend` gate in `run_tests.sh`

**Effort: small. Highest leverage per line.**

**What.** Adopt the Bend convention (`GUIDE.md:287-299`): `LAWS.bend` holds
human-written claims the agent may not edit; `PROOF.bend` holds the agent's
proofs; `bend PROOF.bend` is the gate. Add one line to `run_tests.sh`.

**Why Bend.** This is the feature with no C equivalent whatsoever, and it is the
missing half of the self-improvement loop. Right now `run_tests.sh` is the only
thing standing between Bender and a bad self-edit, and it checks *examples*. A
law checks *all inputs*. The Bend README puts it well: `LAWS.bend` is
`AGENTS.md` backed by proof (`/home/christopherdavid/bend/README.md:96`).

The first laws should be exactly the invariants that, if broken, let the agent
escape its sandbox or corrupt its own repo:

```python
# LAWS.bend
import Base
import ./bender_parse.bend as B

# LAW: Bender never touches an absolute path.
law no_absolute:
  for rest: String
  {B.path_ok(SCon{Chr{47}, rest}) == False{} : Bool}

# LAW: Bender never climbs out of the repository.
law no_dotdot_prefix:
  for rest: String
  {B.path_ok(SCon{Chr{46}, SCon{Chr{46}, rest}}) == False{} : Bool}

# LAW: the empty path is refused.
law no_empty:
  {B.path_ok("") == False{} : Bool}

# LAW: an action survives the round trip through its wire name.
law action_roundtrip:
  for a: B.Action
  {B.parse_action(B.show_action(a)) == a : B.Action}
```

```bash
# run_tests.sh
echo "== laws hold =="
bend PROOF.bend
```

All four of these are proved above, so the gate goes green on day one. Total
cost: about 30 lines. **Then tell the model in `EDIT_FORMAT_SYSTEM`
(`bender_agent.c:308-319`) that `LAWS.bend` is off limits.**

**Law forms worth knowing when you write the next ones.** A law may bind
intermediate values with a `let`, which makes agent-shaped claims readable —
this is how Bend's own game states "winning is impossible"
(`/home/christopherdavid/bend/demos/app_win_is_bug_2d/LAWS.bend:8-11`):

```python
law you_cant_win:
  for moves: List<Game.Move>
  board = Game.replay(Game.start(), moves)
  {Game.is_won(board) == False{} : Bool}
```

The direct analogue for Bender — *"no sequence of parsed edits ever names a path
outside the repo"* — is the law worth aiming at once R5 and R10 land. A law may
also demand a witness with `exs`
(`/home/christopherdavid/bend/evals/firm.looper_cancellation.bend:56-59`) or a
precondition with `where` (`tests/check/assert_full_spec.bend:63-70`). And a
small claim needs no `law` block at all — it can be a def's return type
(`evals/cake.journey_count.bend:27`):

```python
def add_successor(+n: Nat, +m: Nat) -> {Nat.add(n, 1n+m) == 1n+Nat.add(n, m) : Nat}:
```

**Files.** New `LAWS.bend`, new `PROOF.bend`, `run_tests.sh`,
`bender_agent.c` (the system prompt).

**Depends on** R5 (the guard must be in Bend to be provable). A two-edit
sequence: R5 then R3.

---

<a id="r4"></a>
### R4. Typed tool results — no more nullable `char*` triples

**Effort: small.**

**What.** `do_apply_edit` slices three sections and then checks
`if (!path || !old_str || !new_str)` (`bender_agent.c:403-414`). Seven states
are representable; three are meaningful. Model it:

```python
type Edit is Data:
  # the reply was not in the sentinel form at all
  Malformed{why: String}
  # well-formed, but the path is outside the repo
  Refused{path: String}
  # all three sections present and the path passed the guard
  Block{path: String, old_str: String, new_str: String}

type ToolResult is Data:
  Ok{output: String}
  Err{message: String}
```

**Why Bend.** A `Block` cannot be constructed without all three sections *and*
a path that passed `path_ok`, because the only function that builds one runs the
guard. In C the guard is a separate `if` that a future edit can drop. And the
`match` on `Edit` is exhaustive, so "I forgot the refused case" is a compile
error. This also replaces the `strncmp(result, "error:", 6)` convention at
`bender_agent.c:432`, which is string-typing a boolean.

**Files.** New `bender_parse.bend`; consumed by `bender_agent.bend`.

---

<a id="r5"></a>
### R5. Move the sentinel parser and the path guard into Bend

**Effort: medium. Verified working.**

**What.** `slice_section` (`bender_agent.c:324`), `trim_inplace`
(`bender_agent.c:342`) and `path_is_in_repo` (`bender_agent.c:298`) are pure
string functions with no IO. They are the parts most likely to be wrong and the
only parts that can be proved. Move them.

**Why Bend.** Three reasons, in order of importance:

1. **They become provable** (R3). That is the whole game.
2. **They become total and memory-safe.** `slice_section` does pointer
   arithmetic and hands back a `malloc`'d buffer the caller must free; it has
   three `return NULL` paths that the caller must not confuse with an empty
   section — and `test_tools.c:29-32` exists precisely because that distinction
   is subtle. In Bend the empty section and the missing section are different
   constructors and the compiler checks you handled both.
3. **Base already has the pieces** — see R11.

**Sketch** (verified: this compiles and prints `path=[sys_c.c]`):

```python
import Base

# drop characters until `pat` has been consumed
def after.go(s: String, +pat: String, here: Bool) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      match here:
        case True{}:
          String.drop(SCon{h, t}, String.length(pat))
        case False{}:
          after.go(t, pat, String.starts_with(t, pat))

# the text following the first occurrence of pat, or "" when absent
def after(+s: String, +pat: String) -> String:
  after.go(s, pat, String.starts_with(s, pat))

def before.go(s: String, +pat: String, here: Bool) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      match here:
        case True{}:
          SNil{}
        case False{}:
          SCon{h, before.go(t, pat, String.starts_with(t, pat))}

def before(+s: String, +pat: String) -> String:
  before.go(s, pat, String.starts_with(s, pat))

def section(+text: String, +open: String, +close: String) -> String:
  String.trim(before(after(text, open), close))
```

**Gotchas I hit, worth recording in the README.** Both helpers need `+h, +t` on
the match field and `+s` on the parameter; without them Bend rejects with
`consumed more than once`. The `here: Bool` parameter exists only because a
`match` cannot scrutinize `String.starts_with(t, pat)` directly — the caller
computes it and passes it down. That is the same workaround
`bender_agent.bend:135-136` already documents, and it is exactly how Base itself
is written (`bend2/base.bend:1787` `String.starts_with.if`,
`bend2/base.bend:1813` `String.contains.if`). It is idiomatic, not a hack.

**Files.** New `bender_parse.bend`; delete the C twins from `bender_agent.c`
once the Bend loop is the real one.

---

<a id="r6"></a>
### R6. A Bend-side `apply_edit` with verify and rollback

**Effort: medium. Depends on R2.**

**What.** Port the loop's centrepiece — `do_apply_edit`
(`bender_agent.c:500-567`) — to Bend. **I verified this compiles and links
against the existing FFI today:**

```python
import Base
import ./agent_primitives.bend as P

# Verify, then keep or restore. `backup` is the pre-edit snapshot.
def keep_or_rollback(path: String, backup: String, passed: Bool) -> IO(String):
  match passed:
    case True{}:
      IO.pure(String, "verification passed; edit kept")
    case False{}:
      do IO<String>:
        r : String <- P.WriteFile(path, backup)
        return "verification failed; rolled back: " ++ r

def apply_edit(+path: String, old_str: String, new_str: String) -> IO(String):
  do IO<String>:
    backup : String <- P.ReadFile(path)
    res    : String <- P.EditFile(path, old_str, new_str)
    out    : String <- P.Exec("./run_tests.sh > /dev/null 2>&1 && echo PASS || echo FAIL")
    keep_or_rollback(path, backup, String.contains(out, "PASS"))
```

```
$ bend apply_edit_probe.bend -o /tmp/ae.c && gcc -std=c11 -O1 -I. /tmp/ae.c -lpthread -lm -o /tmp/ae_bin
BUILD OK
```

The `&& echo PASS || echo FAIL` shell trick is a workaround for R2; with R2 done
it becomes `match code: case 0: … case _: …`, which is honest.

**Why Bend.** The rollback is the safety property of the whole self-improvement
loop, and in C it depends on `free`/`NULL` discipline across a 67-line function
with eight `free` calls on five paths. In Bend the snapshot is an affine value:
it is either written back or dropped, and there is no third option. The
`keep_or_rollback` match is exhaustive.

**Files.** `bender_agent.bend`.

---

<a id="r7"></a>
### R7. De-duplicate the JSON escapers in C

**Effort: small. A pure-C cleanup and a very good first self-edit.**

`bender_agent.c` contains the *same* seven-line escape loop three times — at
:96-103, :154-161 and :164-171. Meanwhile `agent_primitives.bend:69-89` has a
correct `json_escape` in Bend, and `json_parse_c.c:7-25,28-50` duplicates
`extract_choice` and `extract_content` (`bender_agent.c:198,217`) a fourth and
fifth time.

There is no Bend insight here — it is just duplication, and it is the kind of
duplication that makes an agent's self-edits diverge. Factor one
`static void json_escape_to(FILE*, const char*)`.

The Bend-flavoured version of this recommendation: **the C runtime and the Bend
runtime should not each own a parser.** Long term, `json_parse_c.c` is the only
copy and `bender_agent.c` calls it.

**Files.** `bender_agent.c`.

---

<a id="r8"></a>
### R8. Run `Classify` and the reads concurrently with `IO.fork`

**Effort: medium.**

**What.** Each loop step makes a TypeSafe call and (for `read_code` and
`apply_edit`) an OpenRouter call, strictly in sequence. Several reads in a row
are also sequential. `IO.fork`/`IO.join` overlap them.

**Why Bend.** Because the affinity discipline makes it *safe by construction*.
The guide's claim is that a parallel call's independence "always holds" because
Bend is pure and affine (`GUIDE.md:132-134`). The same reasoning covers forked
`IO`: two forked computations cannot share a mutable buffer because there are no
mutable buffers. Doing this in C means threads, and threads around
`state_append` writing into one `char state[32768]` (`bender_agent.c:271`) is
exactly the bug you do not want in an agent that edits itself.

**Measured**, three forks of a 1000 ms effect:

```
done:a done:b done:c
real    0m1.134s
```

**Sketch** — read three files at once, which is where an agent actually wins:

```python
def read_three(a: String, b: String, c: String) -> IO(String):
  do IO<String>:
    ca : Chan(String) <- IO.fork(String, P.Read(a, 1, 200))
    cb : Chan(String) <- IO.fork(String, P.Read(b, 1, 200))
    cc : Chan(String) <- IO.fork(String, P.Read(c, 1, 200))
    ra : String <- IO.join(String, ca)
    rb : String <- IO.join(String, cb)
    rc : String <- IO.join(String, cc)
    return ra ++ rb ++ rc
```

**The idiom to copy.** Bend's own parallel demos ship a *sequential reference
implementation marked "spec only"* and then prove the parallel version equals
it. `demos/pure_par_sum/main.bend:22-28` defines `seq` with the comment
`# spec for LAWS.bend only`, and `demos/pure_par_sum/LAWS.bend:7-10` states:

```python
law tree_is_seq:
  for +d: Nat
  for +i: Nat
  {Par.sum(d, i) == Par.seq(Par.pow2(d), i) : Nat}
```

proved in 41 lines (`demos/pure_par_sum/PROOF.bend:33-41`). **This is the single
best idiom in the Bend repo for an autonomous agent: parallelize aggressively,
then prove the fast version equals the obvious one.** For Bender the analogue is
"a parallel multi-read returns the same transcript as reading the files one at a
time" — a law that is cheap to state and forecloses the entire class of
concurrency bug that would otherwise make parallelism too risky for a
self-editing agent.

**Caveat, be honest about it.** The win is real only where the work is genuinely
independent. `Classify` and `Generate` in a single step are *not* — the
generation depends on the classification. The wins are: multi-file reads, and
issuing the next step's `Classify` speculatively while a long verify runs. Start
with reads.

**Files.** `bender_agent.bend`.

---

<a id="r9"></a>
### R9. Adopt Bend's `#|` expected-output test convention

**Effort: small. Excellent first candidate.**

**What.** Every file in Bend's test suite ends with the exact output its run must
print, as `#|` comment lines — so a test and its expectation live in one
artifact. (`bend` itself does not check them; Bend's harness does the comparison
at `/home/christopherdavid/bend/gates/test.ts:50`, and the six-line shell
equivalent is below.) Value tests
(`/home/christopherdavid/bend/tests/io/fork_join.bend:34-37`), proof tests
(`tests/proof/vec_safe_lookup.bend:64` → `#|30n`) and even *error* tests pin the
full message including line numbers and `exit 1`
(`tests/check/operator_chain_linear.bend:19-26`).

**Why this matters for Bender specifically.** Right now Bender's only test
artifact is `test_tools.c`, a 70-line C harness that must be *edited in a second
place* every time a behaviour changes — a two-file edit, which is exactly what a
single-hunk self-edit cannot do. With the `#|` convention, a new Bend module
carries its own expectations inline, and `run_tests.sh` just runs `bend` over
every `.bend` file. **A self-editing agent can then add a function and its test
in one hunk.** That is a direct, large improvement to Bender's ability to edit
itself safely.

```python
# bender_parse.bend
def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(section("<<<PATH>>>\nsys_c.c\n<<<OLD>>>\n", "<<<PATH>>>", "<<<OLD>>>"))
    IO.print(Bool.show(path_ok("../secrets")))

#|sys_c.c
#|False
```

```bash
# run_tests.sh — verified working
echo "== every bend module matches its #| expectations =="
for f in *.bend; do
  want=$(grep '^#|' "$f" | sed 's/^#|//')
  [ -z "$want" ] && { bend "$f" >/dev/null || exit 1; continue; }
  got=$(bend "$f")
  [ "$want" = "$got" ] || { echo "FAIL $f"; diff <(echo "$want") <(echo "$got"); exit 1; }
done
```

A file with no `#|` lines is merely type-checked, so this also closes the gap
noted at the end of §7: **every** `.bend` file gets checked, not just the two
reachable from `bender_agent.bend`.

**Files.** every `.bend` file, `run_tests.sh`.

---

<a id="r10"></a>
### R10. The transcript as `List<Step>`, not a string blob

**Effort: medium.**

**What.** The agent's memory is `char state[32768]` (`bender_agent.c:571`) with
`state_append` silently clipping at 6000 bytes per entry
(`bender_agent.c:268-283`) and silently doing nothing at all once the buffer is
nearly full (`bender_agent.c:273`: `if (used + 64 >= cap) return;`). **That is a
silent amnesia bug**: past a certain point the agent stops recording what it
did and cannot tell.

```python
type Step is Data:
  Classified{action: String, confidence: String}
  Observed{label: String, body: String}
  Edited{path: String, kept: Bool}

type Transcript is Data:
  T{n: Nat, steps: List<&2, Step>}   # newest first
```

**Why Bend.** Two reasons. First, retention becomes a policy you can state and
prove rather than a buffer that overflows: keep the newest *k* steps with
`List.take`, and the law "rendering a transcript never exceeds N characters"
is statable. Second — and this is the nice one — **this exact problem is already
solved twice in the Bend repo**:

- `/home/christopherdavid/bend/evals/hard.audit_undo.bend:1-7` is an append-only
  log of `Grant`/`Revoke` actions with an O(1) cached size and an `undo(log, k)`,
  carrying the law "two undos are one undo of the summed count".
- `/home/christopherdavid/bend/evals/firm.tictactoe_undo.bend:238-262` proves
  `undo`/`redo` round-trip — both halves by a single induction returning a pair,
  then split by `undo_redo.fst` / `undo_redo.snd`.

Bender's edit history with rollback is the same structure, and "rolling back an
applied edit restores the previous transcript" is the same law. Read both files
before writing this.

**Caveat.** Bend's `String` is a cons list of `Char` (`bend2/base.bend:63`), so
`++` is O(n) and accumulating is O(n²). I measured: 2000 appends building 80 KB
takes 0.65 s compiled. At agent scale (tens of appends of a few KB) this is
microseconds and irrelevant — but do not build a transcript by repeated `++` in
a hot loop; use `String.concat` / `String.join` (`bend2/base.bend:1868,1882`)
over a list at render time.

**Files.** New `bender_state.bend`.

---

<a id="r11"></a>
### R11. Split the agent into modules

**Effort: small.**

Bend's module system is a plain file-with-an-alias (`GUIDE.md:301-318`) and it
works — `bender_agent.bend:2` already uses it. The natural split:

```
agent_primitives.bend   FFI laws + Classify/Generate + tools      (exists)
bender_parse.bend       path guard, sentinel parser, Action, Edit  (R1/R4/R5)
bender_state.bend       Step, Transcript, rendering                (R10)
bender_ui.bend          the ANSI helpers now at bender_agent.bend:36-61
bender_agent.bend       the loop, and nothing else
LAWS.bend / PROOF.bend  the gate                                   (R3)
```

**Why this matters more for an agent than for a human.** The no-forward-
reference rule means a single file is a strict topological order, and every new
helper must be inserted *above* its first use. That is a nasty constraint for a
model producing one-hunk edits: it has to find the right insertion point, not
just append. Small modules make "append to the end of the right file" correct
far more often. **This is a direct ergonomics win for Bender's own edit loop.**

One caveat found the hard way: constructors of an imported type need the module
prefix in patterns (`case A.ReadCode{}:`).

---

<a id="r12"></a>
### R12. Stop re-implementing Base

**Effort: small; mostly a matter of knowing what is there.**

Bender's C has hand-written versions of things Base already provides. When the
parsing moves to Bend (R5), use these rather than porting the C:

| Bender's C | Use instead | Base |
|---|---|---|
| `trim_inplace` (`bender_agent.c:342`) | `String.trim` / `trim_start` / `trim_end` | `bend2/base.bend:1956,1946,1953` |
| `bender_count_matches` (`tools_c.h:100`) | `String.contains` | `bend2/base.bend:1820` |
| line splitting in `tool_read` (`tools_c.h:219-241`) | `String.lines` | `bend2/base.bend:1911` |
| ad-hoc `strstr`-prefix checks | `String.starts_with` / `ends_with` | `bend2/base.bend:1794,1805` |
| number formatting via `snprintf` | `U32.show` / `Nat.show` / `U32.read` | `bend2/base.bend:2054,1987,2078` |
| `read_cursors[]` fixed array (`bender_agent.c:395`) | `Map` (string-keyed patricia trie) | `bend2/base.bend:2341-2689` |
| the three escape loops (R7) | `json_escape` — **already written in Bend** | `agent_primitives.bend:69-89` |

The `read_cursors` one is worth calling out: `bender_agent.c:395` is a
fixed-size array of per-file read positions with a linear scan. `Map.set` /
`Map.get` (`bend2/base.bend:2491,2553`) is the same thing, unbounded and
already written. Note Base's `Map` threads itself back out of a lookup —
`Map.get` returns `(Map, V)` — because values are linear; that is the one
ergonomic surprise.

**Genuine gaps** where Base has nothing and you must write it: a substring
*index* (only a `Bool` `contains`), `String.split` on a *string* separator (only
on a `Char`, `bend2/base.bend:1904`), any JSON, and `String.replace`. R5's
`after`/`before` fill the first of those.

---

## 5. Not worth doing

Being specific about where C wins matters as much as the recommendations.

**Arrays and in-place mutation for agent state.** Bend's `Array<T>`
(`bend2/base.bend:67`, `GUIDE.md:154-167`) is a complete binary tree with
`Array.swap` (`bend2/base.bend:2171`) as the primitive; every read threads the
array back out because it is `Type`-kinded. It is designed for `2^d`-slot
numeric workloads. Bender's state is a few KB of text rewritten wholesale once
per step — there is no hot indexed update anywhere in the agent. This would be
pure ceremony. **Don't.**

**The GPU `!` and the parallel let.** Covered in §3.4. An agent has no uniform
numeric kernel. `!` would compile and do nothing useful, at the cost of
requiring CUDA 12 or Metal at build time (`GUIDE.md:378-383`). **Don't.**

**HTTPS in Bend.** Base has TCP (`bend2/base.bend:273-295`) and no TLS. The
HTTP demo is raw HTTP on port 80 against a hard-coded IP, and its header comment
says why: *"the TCP kit has no DNS"*
(`/home/christopherdavid/bend/demos/io_http_fetch/main.bend:2`). TypeSafe and
OpenRouter are HTTPS with hostnames. **Shelling to `curl` from C is correct and
should stay.**

**Subprocess execution, `mkdir -p`, `stat`, directory listing.** Base has none
of these — `bend2/effs/` has 35 primitives and not one of them spawns a process
or touches directory metadata. `tools_c.h`'s `bender_mkdir_parents` (:85) and
`bender_is_dir` (:72) have no Bend equivalent and are correct as C. **Keep.**

**Porting `tool_read`'s line-numbering algorithm to Bend.** It handles BOMs,
CRLF, the 256 KB cap and the trailing-newline-counts-as-a-line rule
(`tools_c.h:170-252`). It is well-tested (`test_tools.c:54-67`), it is IO-shaped
anyway, and rewriting it buys no provable property. **Leave it in C.** Note this
is different from R5: the *parser* of the model's reply is pure and provable;
the *file reader* is neither.

**Proving anything about what is on disk.** `IO` is opaque. You cannot state
"after `apply_edit`, the file contains `new_str`". Prove the pure parts and let
`run_tests.sh` cover the rest — which is exactly the division Bend's own demos
use (`demos/io_http_fetch/LAWS.bend:1-3`).

---

## 6. Where Bend is too limited today

Honest blockers, in the order they will bite.

1. **No `argv`.** `bender_agent.c:569` takes the goal from `argv[1]`. A Bend
   agent must use `IO.get_env` (`bend2/base.bend:186`) — `BENDER_GOAL` — and
   `run_bender.sh` has to set it. There is no workaround short of a new FFI
   effect.
2. **No forward references** forces the whole agent into one topological order.
   Mitigated by R10, but it will keep shaping every edit Bender makes to itself.
   It also means a new helper can never be appended to the end of a file that
   uses it — the most natural single-hunk edit a model produces.
3. **No exit status from `Exec`** (R2). Blocks a faithful Bend port of the
   verify/rollback loop.
4. **`match` cannot scrutinize a computed value**, so every branch on a computed
   `Bool` needs a helper taking it as a parameter. This roughly doubles the
   function count in parsing code. It is idiomatic — Base does it everywhere
   (`bend2/base.bend:1787,1813,1939`) — but a model writing Bend will get it
   wrong constantly, so it belongs in `EDIT_FORMAT_SYSTEM`.
5. **`String` is a `Char` cons list.** Fine at agent scale (measured 0.65 s for
   2000 appends totalling 80 KB), but it rules out treating a 256 KB file read
   as a Bend `String` in a loop.
6. **The `CID_*` guard requirement.** Bend emits `#define CID_<NAME>` only for
   laws reachable from `main`, so every FFI section in `sys_c.c` needs its own
   `#ifdef` (`sys_c.c:11-14,30,102,133,173,210`). Every new law must follow
   this or unrelated programs stop compiling. Already handled — keep it that way.
7. **No proof tactics.** A proof is a term (`GUIDE.md:271`). The three laws in
   §3.3 were two `{==}`s and one four-line lemma, so the easy ones really are
   easy — but anything involving induction over `String.contains` will be
   genuine work, and asking a model to produce it is a research question, not a
   task. **Keep the first laws to properties that compute.**

---

## 7. A concrete sequence for Bender to do to itself

Each step is one file, one hunk where possible, verified by `./run_tests.sh` as
it stands (which already checks `bender_agent.bend`, and transitively
`agent_primitives.bend`, at `run_tests.sh:21-23`).

| Step | Edit | Verified by |
|---|---|---|
| 1 | Add `type Action` + `parse_action` + `show_action` to `bender_agent.bend` above `dispatch_action` (R1) | existing `run_tests.sh` |
| 2 | Rewrite `dispatch_action`/`run_action` to `match` on `Action` (R1) | existing |
| 3 | Factor the three duplicate escape loops in `bender_agent.c` into one helper (R7) | existing (`-fsyntax-only` + `test_tools.c`) |
| 4 | Replace `run_tests.sh`'s two hard-coded `bend` invocations with the `#|` loop (R9) | itself |
| 5 | Create `bender_parse.bend` with `path_ok`, `after`, `before`, `section` and its `#|` expectations (R5) | the loop from step 4 |
| 6 | Create `LAWS.bend` + `PROOF.bend` with the four proved laws; add `bend PROOF.bend` to `run_tests.sh` (R3) | the new gate |
| 7 | Add `command.run_status` to `sys_c.c` with its `#ifdef` guard, and `Exec2` to `agent_primitives.bend` (R2) | existing |
| 8 | Add `apply_edit` to `bender_agent.bend` using `Exec2` (R6) | existing |
| 9 | Parallel reads via `IO.fork`, plus the equivalence law (R8) | the gate |

Steps 1–3 are the safest first candidates: single file, single hunk, no new
files, no changes to `run_tests.sh`. **Step 1 is the one to try first.**

**Step 4 is the keystone and is worth doing by hand before turning Bender
loose.** Until `run_tests.sh` checks *every* `.bend` file rather than the two
reachable from `bender_agent.bend` (`run_tests.sh:21-23`), any new Bend module
Bender creates is invisible to its own verifier — and an unverified file is
exactly where a self-improving agent will quietly accumulate damage. It is also
what makes steps 5–9 single-hunk edits instead of two-file ones, because a new
function and its expected output land in the same file.
