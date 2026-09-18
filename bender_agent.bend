import Base
import ./agent_primitives.bend as P
import ./action.bend as A
import ./selector.bend as S

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
  # The tool output to fold into the state before the next round.
  Running{output: String}
  # Classify judged the task done; the loop stops here rather than on fuel.
  Finished{}
  # Classify chose `none`: no listed action fits the state. Halting with the
  # reason beats picking the least-bad action, which is what a Choice with no
  # escape hatch forces, since its probabilities always sum to one.
  Stalled{reason: String}

# The question set lives in selector.bend beside the thresholds and the route
# table that consume them (design rule 8); agent_step asks S.questions().

# Tool output is both shown and folded into the next round's state, so it
# arrives reusable (`+`); affine is the default and would reject the reuse.
def report(+label: String, +out: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{"\n[" ++ label ++ "]:\n" ++ out})

# A model asked for one search string routinely prepends its reasoning, so the
# last non-empty line is taken. Mirrors extract_search_pattern in bender_agent.c.
def keep_last(best: String, line: String) -> String:
  +t = String.trim(line)
  Bool.pick(String, String.is_empty(t), best, t)

def pick_last(ls: List<&2, String>, best: String) -> String:
  List.foldl(~&2, ~String, ~String, ~keep_last, ls, best)

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

def act_generate_answer(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen)

# The action arrives already routed: `none` and unparseable decisions are Stop
# rows in the selector's table upstream, so this match is over Action itself.
def dispatch_action(a: A.Action, state: String) -> IO(Progress):
  match a:
    case A.ReadCode{}:
      act_read_code()
    case A.SearchCode{}:
      act_search_code(state)
    case A.RunBuild{}:
      act_run_build()
    case A.ApplyEdit{}:
      report("apply_edit unavailable", "apply_edit is not implemented in the Bend loop yet; choose another action.")
    case A.GenerateAnswer{}:
      act_generate_answer(state)
    case A.TaskComplete{}:
      IO.pure(Progress, Finished{})

# A route that is not Act lands here: the chosen action is not run and the
# loop re-reads instead, which is the safe fallback every non-acting row
# shares. Confirm carries the same landing — the Bend loop has no one to ask
# mid-run, so an unconfirmed risky action is not run either.
def reroute(+reason: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("   [selector] " ++ reason ++ "; re-reading instead."))
    act_read_code()

# The selector's table decides the step: Act dispatches, the re-read rows take
# the safe fallback, and Stop stalls the loop with the reason it carried.
def run_route(r: S.Route, state: String) -> IO(Progress):
  match r:
    case S.Act{+action}:
      dispatch_action(action, state)
    case S.Reread{+reason}:
      reroute(reason)
    case S.Skip{+reason}:
      reroute(reason)
    case S.Confirm{+action, +reason}:
      reroute(reason ++ " — a person must confirm " ++ A.show_action(action) ++ " before it runs")
    case S.Stop{+reason}:
      IO.pure(Progress, Stalled{reason})

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

# The step's answers print as one line and route through the selector's table:
# every decision the old dispatch made inline — `none`, unparseable, missing,
# the confidence floor — is a row there now. `answers` is reusable so it can
# be both opened for the note and handed to route whole.
def run_answers(+answers: S.LoopAnswers, state: String) -> IO(Progress):
  match answers:
    case S.Ans{+action, +blocked, repeats, asked, risk, +progress}:
      do IO<Progress>:
        u1 : Unit <- IO.print(
          color_yellow("[Classify Decision] ") ++ color_bold(answer_note(action)) ++
          color_yellow(" (blocked " ++ answer_note(blocked) ++
          ", progress " ++ answer_note(progress) ++ ")"))
        u2 : Unit <- IO.print("")
        run_route(S.route(answers), state)

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
        +c_raw : String <- P.Classify(state ++ output, S.questions())
        action : P.Answer <- P.ParseAnswer(c_raw, "action")
        blocked : P.Answer <- P.ParseAnswer(c_raw, "is_blocked")
        repeats : P.Answer <- P.ParseAnswer(c_raw, "repeats")
        asked : P.Answer <- P.ParseAnswer(c_raw, "needs_code_change")
        risk : P.Answer <- P.ParseAnswer(c_raw, "risk")
        progress : P.Answer <- P.ParseAnswer(c_raw, "progress_score")
        next : Progress <- run_answers(S.Ans{action, blocked, repeats, asked, risk, progress}, state ++ output)
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
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, Result.default(&1, &1, U32 & String, String, env, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
