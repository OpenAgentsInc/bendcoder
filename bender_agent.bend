import Base
import ./agent_primitives.bend as P

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

# Questions asked of TypeSafe System One at each step of the loop
def loop_triage_questions() -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "action",
      "Based on the current state, what is the single next best action to advance or verify the task?",
      [
        P.Opt{"read_code", "Read source code or repository files to understand context or inspect implementations"},
        P.Opt{"run_build", "Run build, compile, or test command to check if code works or reproduces an error"},
        P.Opt{"generate_fix", "Synthesize code, write a patch, or generate a fix using the LLM"},
        P.Opt{"task_complete", "The task is successfully resolved, verified, and complete"}
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
def report(label: String, +out: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{"\n[" ++ label ++ "]:\n" ++ out})

def act_run_build() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL EXEC] Running verification: './run_tests.sh' ..."))
    out : String <- P.Exec("./run_tests.sh")
    report("Verification Output", out)

def act_read_code() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL READ] Reading 'hello.bend' ..."))
    content : String <- P.Read("hello.bend", 1, 200)
    report("hello.bend (lines 1-200)", content)

def act_generate_fix(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen)

# A match can only scrutinize a parameter or a field, never a computed value,
# so the equality tests are made by the caller and dispatched on here.
def dispatch_action(is_complete: Bool, is_build: Bool, is_read: Bool, state: String) -> IO(Progress):
  match is_complete:
    case True{}:
      IO.pure(Progress, Finished{})
    case False{}:
      match is_build:
        case True{}:
          act_run_build()
        case False{}:
          match is_read:
            case True{}:
              act_read_code()
            case False{}:
              act_generate_fix(state)

# `decision` is printed once and compared three times, hence `+`.
def run_action(+decision: String, state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_yellow("[Classify Decision] ") ++ color_bold(decision))
    u2 : Unit <- IO.print("")
    dispatch_action(
      String.eq(decision, "task_complete"),
      String.eq(decision, "run_build"),
      String.eq(decision, "read_code"),
      state
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
    case 0n Running{output}:
      IO.print(color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+output}:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_cyan(rule()))
        u2 : Unit <- IO.print(color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(color_cyan(rule()))
        c_raw : String <- P.Classify(state ++ output, loop_triage_questions())
        decision : String <- extract.choice(c_raw, "action")
        next : Progress <- run_action(decision, state ++ output)
        agent_step(p, next, (step_num + 1 : U32), state ++ output)

# The goal is both announced and seeded into the state, so it arrives reusable.
def run_agent(fuel: Nat, +goal: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- render_banner()
    u2 : Unit <- IO.print(color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    agent_step(fuel, Running{""}, 1, goal)

def main() -> IO(Unit):
  run_agent(4n, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating.")
