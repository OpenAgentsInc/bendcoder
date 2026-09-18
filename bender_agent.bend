import Base
import ./agent_primitives.bend as P
import ./action.bend as A

# ==============================================================================
# Bender: Autonomous Coding Agent Loop & Terminal UI
# ==============================================================================
# Classify, Generate, the question types and the file tools all live in
# agent_primitives.bend and are reached here through `P.`; this file is only
# the loop and the terminal UI built on top of them.
# ==============================================================================

# ------------------------------------------------------------------------------
# FFI Bindings: JSON field extraction
# ------------------------------------------------------------------------------
law extract.choice:
  String -> String -> IO(String)

def extract.choice(json, qid):
  import "./json_parse_c.c"

law extract.generation:
  String -> IO(String)

def extract.generation(json):
  import "./json_parse_c.c"

# Generate, with the model's reply lifted out of the OpenRouter envelope.
def GenerateText(model: String, system_prompt: String, prompt: String) -> IO(String):
  do IO<String>:
    raw : String <- P.Generate(model, system_prompt, prompt)
    extract.generation(raw)

# ------------------------------------------------------------------------------
# Terminal UI Formatting Helpers
# ------------------------------------------------------------------------------
def esc() -> String:
  Char.show(Chr{27})

def color_cyan(s: String) -> String:
  esc() ++ "[36m" ++ s ++ esc() ++ "[0m"

def color_green(s: String) -> String:
  esc() ++ "[32m" ++ s ++ esc() ++ "[0m"

def color_yellow(s: String) -> String:
  esc() ++ "[33m" ++ s ++ esc() ++ "[0m"

def color_magenta(s: String) -> String:
  esc() ++ "[35m" ++ s ++ esc() ++ "[0m"

def color_bold(s: String) -> String:
  esc() ++ "[1m" ++ s ++ esc() ++ "[0m"

def rule() -> String:
  "--------------------------------------------------------------------------------"

def render_banner() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_cyan("================================================================================"))
    u2 : Unit <- IO.print(color_bold("  [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)"))
    IO.print(color_cyan("================================================================================"))


# ------------------------------------------------------------------------------
# Autonomous Agent Loop
# ------------------------------------------------------------------------------
# Bend 2.0.5 resolves names in order and has no forward references, so the loop
# cannot be a set of handlers that call back into the step function. It is one
# self-recursive `agent_step` instead: every handler returns a `Progress` and
# `agent_step` alone decides whether to go round again.

type Progress is Data:
  # The tool output to fold into the state before the next round, plus the
  # running count of consecutive search misses — the loop's own record of a
  # search_code that keeps failing, since nothing else notices it.
  Running{output: String, misses: U32}
  # Classify judged the task done; the loop stops here rather than on fuel.
  Finished{}
  # Classify chose `none`: no listed action fits the state. Halting with the
  # reason beats picking the least-bad action, which is what a Choice with no
  # escape hatch forces, since its probabilities always sum to one.
  Stalled{reason: String}

# Questions asked of TypeSafe System One at each step of the loop
def loop_triage_questions() -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "action",
      "Based on the current state, what is the single next best action to advance or verify the task?",
      [
        P.Opt{A.show_action(A.ReadCode{}), "Read source code or repository files to understand context or inspect implementations"},
        P.Opt{A.show_action(A.SearchCode{}), "Search the repository for a literal string to find which files are relevant"},
        P.Opt{A.show_action(A.RunBuild{}), "Run build, compile, or test command to check if code works or reproduces an error"},
        P.Opt{A.show_action(A.GenerateAnswer{}), "Synthesize code, write a patch, or generate a fix using the LLM"},
        P.Opt{A.show_action(A.TaskComplete{}), "The task is successfully resolved, verified, and complete"},
        P.Opt{"none", "No listed action fits: the state does not yet support a next step"}
      ]
    },
    P.NoulQ{
      "is_blocked",
      "Is the task blocked by an error or failing verification?"
    },
    P.ScoreQ{
      "progress_score",
      "How close is the current state to a fully verified resolution?",
      [
        "0: Just starting / investigating",
        "1: Root cause understood, attempting fix",
        "2: Fully fixed, verified, and ready to finish"
      ]
    }
  ]

# Tool output is both shown and folded into the next round's state, so it
# arrives reusable (`+`); affine is the default and would reject the reuse.
def report_misses(+label: String, +out: String, misses: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{"\n[" ++ label ++ "]:\n" ++ out, misses})

# Anything that is not a search breaks the miss run, so a plain report resets
# the count to zero.
def report(+label: String, +out: String) -> IO(Progress):
  report_misses(label, out, 0)

# A model asked for one search string routinely prepends its reasoning, so the
# last non-empty line is taken. Mirrors extract_search_pattern in bender_agent.c.
def keep_last(best: String, line: String) -> String:
  +t = String.trim(line)
  Bool.pick(String, String.is_empty(t), best, t)

def pick_last(ls: List<&2, String>, best: String) -> String:
  List.foldl(~&2, ~String, ~String, ~keep_last, ls, best)

# A miss reads as the text tool_grep returns for one; an "error:" result (an
# empty pattern, a bad path) is a failed search all the same. A retry that
# found hits case-insensitively still says "No matches found", so that phrase
# only counts as a miss when nothing follows it.
def search_missed(+hits: String) -> Bool:
  Bool.or(
    Bool.and(String.contains(hits, "No matches found"),
             Bool.not(String.contains(hits, "case-insensitive"))),
    String.contains(hits, "error:"))

# The report labels every search with its pattern, which is what lets the
# contains-check below recognise a re-proposed one.
def search_report(+pattern: String, +hits: String, prev: U32) -> IO(Progress):
  report_misses(
    "Search for '" ++ pattern ++ "'",
    hits,
    Bool.pick(U32, search_missed(hits), U32.inc(prev), 0))

def search_with(+pattern: String, prev: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL SEARCH] Searching for '") ++ pattern ++ color_magenta("' ..."))
    hits : String <- P.Grep(pattern, ".")
    search_report(pattern, hits, prev)

# A pattern already run is in the state with its result, so proposing it again
# is a failed search without even grepping: skipped, but counted all the same.
def act_search_code.go(+pattern: String, prev: U32, already: Bool) -> IO(Progress):
  match already:
    case True{}:
      report_misses(
        "Search skipped",
        "'" ++ pattern ++ "' was already searched; its result is in the state above. Propose a shorter or different string, or read a file instead.",
        U32.inc(prev))
    case False{}:
      search_with(pattern, prev)

# The already-searched test is a computed value, which a match cannot inspect,
# so it is evaluated here and handed to `go` as a Bool parameter.
def act_search_code.check(state: String, +pattern: String, prev: U32) -> IO(Progress):
  act_search_code.go(pattern, prev, String.contains(state, "Search for '" ++ pattern ++ "'"))

def act_search_code(+state: String, prev: U32) -> IO(Progress):
  do IO<Progress>:
    reply : String <- GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You choose one literal search string. Reply with the string alone, nothing else.",
      "State:\n" ++ state ++ "\nGive one literal string to search this repository for. Not a regular expression. A fragment of the right name beats a full guess at it."
    )
    act_search_code.check(state, pick_last(String.lines(reply), ""), prev)

# Exec returns Done{output} or Fail{(code, output)}, so the loop can finally
# tell a passing verification from a failing one. A match scrutinizes only a
# parameter, hence the split.
def verify_failed(codeout: U32 & String) -> IO(Progress):
  (code, out) = codeout
  report("Verification FAILED (exit " ++ U32.show(code) ++ ")", out)

def verify_passed(out: String) -> IO(Progress):
  report("Verification passed", out)

def report_verify(r: Result<&1, &1, U32 & String, String>) -> IO(Progress):
  match r:
    case Fail{e}:
      verify_failed(e)
    case Done{v}:
      verify_passed(v)

def act_run_build() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL EXEC] Running verification: './run_tests.sh' ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec("./run_tests.sh")
    report_verify(r)

def act_read_code() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL READ] Reading 'hello.bend' ..."))
    content : String <- P.Read("hello.bend", 1, 200)
    report("hello.bend (lines 1-200)", content)

def prepend_search_note(p: Progress) -> IO(Progress):
  match p:
    case Running{output, misses}:
      IO.pure(Progress, Running{
        "\n[Search kept missing]: search_code missed twice running; read_code was run instead." ++ output,
        misses})
    case other:
      IO.pure(Progress, other)

# A search that keeps missing is not converging, and nothing else in the loop
# notices on its own: the same nudge that turns an early apply_edit into a
# read in the C loop sends a repeatedly-missing search_code at read_code.
def search_stuck_read() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("   [SEARCH STUCK] search_code missed twice running; reading code instead."))
    p : Progress <- act_read_code()
    prepend_search_note(p)

def act_generate_answer(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen)

# The action arrives already decoded: is_none keeps "none" (a real decision —
# no listed action fits) distinct from None{} (a decision string no action
# owns, which used to fall through to generate_answer), and the match is
# exhaustive over the Action type. `misses` is the running count of failed
# searches; `search_stuck` is its comparison against the limit, computed by
# the caller because a match cannot inspect a computed value.
def dispatch_action(is_none: Bool, a: Maybe<&2, A.Action>, state: String, misses: U32, search_stuck: Bool) -> IO(Progress):
  match is_none a search_stuck:
    case True{} _ _:
      IO.pure(Progress, Stalled{"Classify reported that no listed action fits the current state."})
    case _ None{} _:
      IO.pure(Progress, Stalled{"Classify returned a decision that names no action."})
    case _ Some{A.SearchCode{}} True{}:
      search_stuck_read()
    case _ Some{A.ReadCode{}} _:
      act_read_code()
    case _ Some{A.SearchCode{}} _:
      act_search_code(state, misses)
    case _ Some{A.RunBuild{}} _:
      act_run_build()
    case _ Some{A.ApplyEdit{}} _:
      report("apply_edit unavailable", "apply_edit is not implemented in the Bend loop yet; choose another action.")
    case _ Some{A.GenerateAnswer{}} _:
      act_generate_answer(state)
    case _ Some{A.TaskComplete{}} _:
      IO.pure(Progress, Finished{})

# `decision` is printed once, compared once and parsed once, hence `+`.
def run_action(+decision: String, state: String, +misses: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("[Classify Decision] ") ++ color_bold(decision))
    u2 : Unit <- IO.print("")
    dispatch_action(
      String.eq(decision, "none"),
      A.parse_action(decision),
      state,
      misses,
      U32.is_ge(misses, 2)
    )

# One round: fold the last tool output into the state, classify it, run the
# chosen action, and recurse on the remaining fuel.
# `fuel` leads the parameter list on two counts: a match reads its scrutinees in
# binder order, and a self-call must pass every argument unchanged until one
# shrinks — so the argument that shrinks has to come first.
def agent_step(fuel: Nat, phase: Progress, +step_num: U32, +state: String) -> IO(Unit):
  match fuel phase:
    # Finishing wins over exhaustion: a task completed on the last step is
    # reported as complete, not as having run out of fuel.
    case f Finished{}:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_green("[TASK COMPLETED] Bender verified all goals are met!"))
        IO.print(color_cyan("================================================================================"))
    case f Stalled{reason}:
      IO.print(color_yellow("[STALLED] ") ++ reason)
    case 0n Running{output, _}:
      IO.print(color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+output, misses}:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_cyan(rule()))
        u2 : Unit <- IO.print(color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(color_cyan(rule()))
        c_raw : String <- P.Classify(state ++ output, loop_triage_questions())
        decision : String <- extract.choice(c_raw, "action")
        next : Progress <- run_action(decision, state ++ output, misses)
        agent_step(p, next, (step_num + 1 : U32), state ++ output)

# The goal is both announced and seeded into the state, so it arrives reusable.
def run_agent(fuel: Nat, +goal: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- render_banner()
    u2 : Unit <- IO.print(color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    agent_step(fuel, Running{"", 0}, 1, goal)

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bender_agent.c takes it from argv[1].
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, Result.default(&1, &1, U32 & String, String, env, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
