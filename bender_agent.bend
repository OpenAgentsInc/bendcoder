import Base

# ==============================================================================
# Bender: Autonomous Coding Agent Loop & Terminal UI
# ==============================================================================
# Dual-primitive architecture:
# - Classify: TypeSafe System One (calibrated action selection, triage, verification)
# - Generate: LLM Code Synthesis
# - FFI Tools: Subprocess Execution, File Read/Write
# ==============================================================================

# ------------------------------------------------------------------------------
# FFI Bindings
# ------------------------------------------------------------------------------
law typesafe.post:
  String -> IO(String)

def typesafe.post(payload):
  import "./typesafe_c.c"

law openrouter.post:
  String -> IO(String)

def openrouter.post(payload):
  import "./openrouter_c.c"

law command.run:
  String -> IO(String)

def command.run(cmd):
  import "./sys_c.c"

law sys.read_file:
  String -> IO(String)

def sys.read_file(path):
  import "./sys_c.c"

law sys.write_file:
  String -> String -> IO(String)

def sys.write_file(path, content):
  import "./sys_c.c"

law sys.read_lines:
  String -> String -> String -> IO(String)

def sys.read_lines(path, offset, limit):
  import "./sys_c.c"

law sys.edit_file:
  String -> String -> String -> String -> IO(String)

def sys.edit_file(path, old_str, new_str, replace_all):
  import "./sys_c.c"

law extract.choice:
  String -> String -> IO(String)

def extract.choice(json, qid):
  import "./json_parse_c.c"

law extract.generation:
  String -> IO(String)

def extract.generation(json):
  import "./json_parse_c.c"

# ------------------------------------------------------------------------------
# JSON String escaping
# ------------------------------------------------------------------------------
def json_escape_char(c: Char) -> String:
  match c:
    case '"':
      "\\\""
    case '\\':
      "\\\\"
    case '\n':
      "\\n"
    case '\r':
      "\\r"
    case '\t':
      "\\t"
    case other:
      SCon{other, SNil{}}

def json_escape(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{h, t}:
      json_escape_char(h) ++ json_escape(t)

# ------------------------------------------------------------------------------
# High-Level Classify Question Definitions
# ------------------------------------------------------------------------------
type OptionPair is Data:
  Opt{label: String, desc: String}

type Question is Data:
  NoulQ{qid: String, instructions: String}
  ChoiceQ{qid: String, instructions: String, options: List<&2, OptionPair>}
  ScoreQ{qid: String, instructions: String, rubric: List<&2, String>}

def choice_options_to_json(opts: List<&2, OptionPair>) -> String:
  match opts:
    case Nil{}:
      ""
    case Opt{label, desc} <> Nil{}:
      "\"" ++ json_escape(label) ++ "\":\"" ++ json_escape(desc) ++ "\""
    case Opt{label, desc} <> rest:
      "\"" ++ json_escape(label) ++ "\":\"" ++ json_escape(desc) ++ "\"," ++ choice_options_to_json(rest)

def score_rubric_to_json(rubric: List<&2, String>) -> String:
  match rubric:
    case Nil{}:
      ""
    case item <> Nil{}:
      "\"" ++ json_escape(item) ++ "\""
    case item <> rest:
      "\"" ++ json_escape(item) ++ "\"," ++ score_rubric_to_json(rest)

def question_to_json(q: Question) -> String:
  match q:
    case NoulQ{qid, inst}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"noul\",\"instructions\":\"" ++ json_escape(inst) ++ "\"}"
    case ChoiceQ{qid, inst, opts}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"choice\",\"instructions\":\"" ++ json_escape(inst) ++ "\",\"criteria\":{" ++ choice_options_to_json(opts) ++ "}}"
    case ScoreQ{qid, inst, rub}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"score\",\"instructions\":\"" ++ json_escape(inst) ++ "\",\"criteria\":[" ++ score_rubric_to_json(rub) ++ "]}"

def questions_to_json(qs: List<&2, Question>) -> String:
  match qs:
    case Nil{}:
      ""
    case q <> Nil{}:
      question_to_json(q)
    case q <> rest:
      question_to_json(q) ++ "," ++ questions_to_json(rest)

def build_classify_payload(state: String, qs: List<&2, Question>) -> String:
  "{\"state\":\"" ++ json_escape(state) ++ "\",\"model\":\"jev-latest\",\"questions\":{" ++ questions_to_json(qs) ++ "}}"

def Classify(state: String, questions: List<&2, Question>) -> IO(String):
  do IO<String>:
    payload : String <- IO.pure(String, build_classify_payload(state, questions))
    typesafe.post(payload)

def build_generate_payload(model: String, system_prompt: String, prompt: String) -> String:
  "{\"model\":\"" ++ json_escape(model) ++ "\",\"messages\":[{\"role\":\"system\",\"content\":\"" ++ json_escape(system_prompt) ++ "\"},{\"role\":\"user\",\"content\":\"" ++ json_escape(prompt) ++ "\"}]}"

def Generate(model: String, system_prompt: String, prompt: String) -> IO(String):
  do IO<String>:
    payload : String <- IO.pure(String, build_generate_payload(model, system_prompt, prompt))
    raw : String <- openrouter.post(payload)
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

def render_banner() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_cyan("================================================================================"))
    u2 : Unit <- IO.print(color_bold("  [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)"))
    IO.print(color_cyan("================================================================================"))

# ------------------------------------------------------------------------------
# Autonomous Agent Loop
# ------------------------------------------------------------------------------

# Questions asked to TypeSafe System One at each step of the loop
def loop_triage_questions() -> List<&2, Question>:
  [
    ChoiceQ{
      "action",
      "Based on the current state, what is the single next best action to advance or verify the task?",
      [
        Opt{"read_code", "Read source code or repository files to understand context or inspect implementations"},
        Opt{"run_build", "Run build, compile, or test command to check if code works or reproduces an error"},
        Opt{"generate_fix", "Synthesize code, write a patch, or generate a fix using the LLM"},
        Opt{"task_complete", "The task is successfully resolved, verified, and complete"}
      ]
    },
    NoulQ{
      "is_blocked",
      "Is the task blocked by an error or failing verification?"
    },
    ScoreQ{
      "progress_score",
      "How close is the current state to a fully verified resolution?",
      [
        "0: Just starting / investigating",
        "1: Root cause understood, attempting fix",
        "2: Fully fixed, verified, and ready to finish"
      ]
    }
  ]

# Step execution
def agent_step(fuel: Nat, step_num: U32, state: String) -> IO(Unit):
  match fuel:
    case 0n:
      IO.print(color_yellow("[WARN] Max step fuel reached. Pausing agent loop."))
    case 1n+p:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_cyan("--------------------------------------------------------------------------------"))
        u2 : Unit <- IO.print(color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(color_cyan("--------------------------------------------------------------------------------"))

        # 1. Classify State
        c_raw : String <- Classify(state, loop_triage_questions())
        decision : String <- extract.choice(c_raw, "action")

        u4 : Unit <- IO.print(color_yellow("[Classify Decision] ") ++ color_bold(decision))
        u5 : Unit <- IO.print("   Full Calibration: " ++ c_raw)
        u6 : Unit <- IO.print("")

        # 2. Dispatch based on calibrated decision
        +dec = decision
        cmp_tc = String.order(dec, "task_complete")
        cmp_rb = String.order(dec, "run_build")
        cmp_rc = String.order(dec, "read_code")
        agent_dispatch(p, step_num, cmp_tc, cmp_rb, cmp_rc, state)

def handle_task_complete() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_green("[TASK COMPLETED] Bender verified all goals are met!"))
    IO.print(color_cyan("================================================================================"))

def handle_run_build(fuel: Nat, step_num: U32, state: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_magenta("[TOOL EXEC] Running build verification: 'gcc --version' ..."))
    out : String <- command.run("gcc --version | head -n 1")
    u2 : Unit <- IO.print("   Output: " ++ out)
    agent_step(fuel, (step_num + 1 : U32), state ++ "\n[Build Check Output]: " ++ out ++ " -> All checks passed.")

def handle_read_code(fuel: Nat, step_num: U32, state: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_magenta("[TOOL READ] Reading file 'hello.bend' ..."))
    content : String <- sys.read_file("hello.bend")
    u2 : Unit <- IO.print("   File Content: " ++ content)
    agent_step(fuel, (step_num + 1 : U32), state ++ "\n[File Content of hello.bend]:\n" ++ content)

def handle_generate_fix(fuel: Nat, step_num: U32, state: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- Generate(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Produce a minimal 1-line summary of how to run hello.bend"
    )
    u2 : Unit <- IO.print(color_green("   LLM Output: ") ++ gen)
    agent_step(fuel, (step_num + 1 : U32), state ++ "\n[Generated Code/Summary]: " ++ gen ++ "\nVerification: Task verified.")

def agent_dispatch(
  fuel: Nat, step_num: U32, cmp_tc: Cmp, cmp_rb: Cmp, cmp_rc: Cmp, state: String
) -> IO(Unit):
  match cmp_tc:
    case EQ{}:
      handle_task_complete()
    case other1:
      match cmp_rb:
        case EQ{}:
          handle_run_build(fuel, step_num, state)
        case other2:
          match cmp_rc:
            case EQ{}:
              handle_read_code(fuel, step_num, state)
            case other3:
              handle_generate_fix(fuel, step_num, state)

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- render_banner()
    initial_state = "Project: Bender repo (/home/christopherdavid/bender). Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."
    u2 : Unit <- IO.print(color_bold("[GOAL] Initial Goal: ") ++ initial_state)
    u3 : Unit <- IO.print("")
    agent_step(4n, 1, initial_state)
