import Base
import ./agent_primitives.bend as P

# ==============================================================================
# Bender: Autonomous Coding Agent Loop & Terminal UI
# ==============================================================================
# Classify, Generate, the question and answer types and the file tools all
# live in agent_primitives.bend and are reached here through `P.`; this file
# is only the loop and the terminal UI built on top of them.
# ==============================================================================

# ------------------------------------------------------------------------------
# Terminal UI Formatting Helpers
# ------------------------------------------------------------------------------
def esc() -> String:
  SCon{Chr{27}, SNil{}}

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
  # The tool output to fold into the state before the next round.
  Running{output: String}
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
        P.Opt{"read_code", "Read source code or repository files to understand context or inspect implementations"},
        P.Opt{"search_code", "Search the repository for a literal string to find which files are relevant"},
        P.Opt{"run_build", "Run build, compile, or test command to check if code works or reproduces an error"},
        P.Opt{"generate_fix", "Synthesize code, write a patch, or generate a fix using the LLM"},
        P.Opt{"task_complete", "The task is successfully resolved, verified, and complete"},
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
def report(+label: String, +out: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{"\n[" ++ label ++ "]:\n" ++ out})

# A model asked for one search string routinely prepends its reasoning, so the
# last non-empty line is taken. Mirrors extract_search_pattern in bender_agent.c.
# A match cannot scrutinize a computed value, so the emptiness test is made by
# the caller and dispatched on here.
def choose_line(is_blank: Bool, line: String, best: String) -> String:
  match is_blank:
    case True{}:
      best
    case False{}:
      line

def pick_last(ls: List<&2, String>, best: String) -> String:
  match ls:
    case Nil{}:
      best
    case +l <> rest:
      pick_last(rest, choose_line(String.is_empty(String.trim(l)), String.trim(l), best))

def search_with(+pattern: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL SEARCH] Searching for '") ++ pattern ++ color_magenta("' ..."))
    hits : String <- P.Grep(pattern, ".")
    report("Search Hits", hits)

def act_search_code(state: String) -> IO(Progress):
  do IO<Progress>:
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You choose one literal search string. Reply with the string alone, nothing else.",
      "State:\n" ++ state ++ "\nGive one literal string to search this repository for. Not a regular expression."
    )
    search_with(pick_last(String.lines(reply), ""))

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

def act_generate_fix(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen)

# A match can only scrutinize a parameter or a field, never a computed value,
# so the equality tests are made by the caller and dispatched on here.
def dispatch_action(
  is_complete: Bool, is_none: Bool, is_build: Bool, is_read: Bool, is_search: Bool,
  state: String
) -> IO(Progress):
  match is_complete:
    case True{}:
      IO.pure(Progress, Finished{})
    case False{}:
      match is_none:
        case True{}:
          IO.pure(Progress, Stalled{"Classify reported that no listed action fits the current state."})
        case False{}:
          match is_build:
            case True{}:
              act_run_build()
            case False{}:
              match is_read:
                case True{}:
                  act_read_code()
                case False{}:
                  match is_search:
                    case True{}:
                      act_search_code(state)
                    case False{}:
                      act_generate_fix(state)

# The short note an answer makes on the step line, for the questions that are
# not the action itself. Missing reads as what it is — the request gave no
# answer — not as a zero.
def answer_note(a: P.Answer) -> String:
  match a:
    case P.Chosen{+choice, +confidence}:
      choice ++ " (confidence " ++ F32.show(confidence) ++ ")"
    case P.Scored{+score, +confidence}:
      F32.show(score) ++ " (confidence " ++ F32.show(confidence) ++ ")"
    case P.Nouled{+probability}:
      F32.show(probability)
    case P.Missing{+reason}:
      "missing: " ++ reason

# A match scrutinizes only a parameter, so the typed answers arrive here and
# the action's own case decides the step. `choice` is printed once and
# compared five times, hence `+`. A missing or mistyped answer stalls the loop
# rather than falling through to a generation it never chose — #32's case.
def run_answers(action: P.Answer, blocked: P.Answer, progress: P.Answer, state: String) -> IO(Progress):
  match action:
    case P.Chosen{+choice, +confidence}:
      do IO<Progress>:
        u1 : Unit <- IO.print(
          color_yellow("[Classify Decision] ") ++ color_bold(choice) ++
          color_yellow(" (confidence " ++ F32.show(confidence) ++
          ", blocked " ++ answer_note(blocked) ++
          ", progress " ++ answer_note(progress) ++ ")"))
        u2 : Unit <- IO.print("")
        dispatch_action(
          String.eq(choice, "task_complete"),
          String.eq(choice, "none"),
          String.eq(choice, "run_build"),
          String.eq(choice, "read_code"),
          String.eq(choice, "search_code"),
          state
        )
    case P.Missing{+reason}:
      IO.pure(Progress, Stalled{"Classify returned no answer: " ++ reason})
    case P.Scored{+score, +confidence}:
      IO.pure(Progress, Stalled{"Classify answered 'action' with a score (" ++ F32.show(score) ++ "), not a choice."})
    case P.Nouled{+probability}:
      IO.pure(Progress, Stalled{"Classify answered 'action' with a noul (" ++ F32.show(probability) ++ "), not a choice."})

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
    case 0n Running{output}:
      IO.print(color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+output}:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_cyan(rule()))
        u2 : Unit <- IO.print(color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(color_cyan(rule()))
        +c_raw : String <- P.Classify(state ++ output, loop_triage_questions())
        action : P.Answer <- P.ParseAnswer(c_raw, "action")
        blocked : P.Answer <- P.ParseAnswer(c_raw, "is_blocked")
        progress : P.Answer <- P.ParseAnswer(c_raw, "progress_score")
        next : Progress <- run_answers(action, blocked, progress, state ++ output)
        agent_step(p, next, (step_num + 1 : U32), state ++ output)

# The goal is both announced and seeded into the state, so it arrives reusable.
def run_agent(fuel: Nat, +goal: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- render_banner()
    u2 : Unit <- IO.print(color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    agent_step(fuel, Running{""}, 1, goal)

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bender_agent.c takes it from argv[1].
def goal_or_default(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Fail{e}:
      "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."
    case Done{v}:
      v

def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, goal_or_default(env))
