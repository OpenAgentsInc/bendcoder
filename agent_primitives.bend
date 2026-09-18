import Base

# ==============================================================================
# Bender Agent Core: Classify & Generate
# ==============================================================================
# In Bender, the agent loop is simplified to two core primitives:
# 1. Classify: Fast, calibrated decision making using TypeSafe System One.
#              Given the agent's current state (context, errors, code, instructions)
#              and structured questions (Choice, Score, Noul), Classify yields
#              deterministic routing and probabilities.
# 2. Generate: Generative synthesis (writing code, generating responses, diffs)
#              powered by LLMs (OpenRouter / OpenAI-compatible / Gemini).
# ==============================================================================

# ------------------------------------------------------------------------------
# Low-level FFI: TypeSafe System One
# ------------------------------------------------------------------------------
law typesafe.post:
  String -> IO(String)

def typesafe.post(payload):
  import "./typesafe_c.c"
  import "./typesafe_c.js"

# ------------------------------------------------------------------------------
# Low-level FFI: OpenRouter / LLM Generation
# ------------------------------------------------------------------------------
law openrouter.post:
  String -> IO(String)

def openrouter.post(payload):
  import "./openrouter_c.c"
  import "./openrouter_c.js"

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

# Key-value pair of data strings (e.g. choice label and description)
type OptionPair is Data:
  Opt{label: String, desc: String}

type Question is Data:
  # Noul: yes/no question evaluated to calibrated probability [0.0, 1.0]
  NoulQ{qid: String, instructions: String}
  # Choice: choose best matching label from a list of option pairs
  ChoiceQ{qid: String, instructions: String, options: List<&2, OptionPair>}
  # Score: evaluate along an ordered rubric of levels [level0, level1, ...]
  ScoreQ{qid: String, instructions: String, rubric: List<&2, String>}

# Serialize Choice options into JSON map
def choice_options_to_json(opts: List<&2, OptionPair>) -> String:
  match opts:
    case Nil{}:
      ""
    case Opt{label, desc} <> Nil{}:
      "\"" ++ json_escape(label) ++ "\":\"" ++ json_escape(desc) ++ "\""
    case Opt{label, desc} <> rest:
      "\"" ++ json_escape(label) ++ "\":\"" ++ json_escape(desc) ++ "\"," ++ choice_options_to_json(rest)

# Serialize Score rubric into JSON array
def score_rubric_to_json(rubric: List<&2, String>) -> String:
  match rubric:
    case Nil{}:
      ""
    case item <> Nil{}:
      "\"" ++ json_escape(item) ++ "\""
    case item <> rest:
      "\"" ++ json_escape(item) ++ "\"," ++ score_rubric_to_json(rest)

# Serialize single question to JSON
def question_to_json(q: Question) -> String:
  match q:
    case NoulQ{qid, inst}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"noul\",\"instructions\":\"" ++ json_escape(inst) ++ "\"}"
    case ChoiceQ{qid, inst, opts}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"choice\",\"instructions\":\"" ++ json_escape(inst) ++ "\",\"criteria\":{" ++ choice_options_to_json(opts) ++ "}}"
    case ScoreQ{qid, inst, rub}:
      "\"" ++ json_escape(qid) ++ "\":{\"type\":\"score\",\"instructions\":\"" ++ json_escape(inst) ++ "\",\"criteria\":[" ++ score_rubric_to_json(rub) ++ "]}"

# Serialize list of questions to JSON map body
def questions_to_json(qs: List<&2, Question>) -> String:
  match qs:
    case Nil{}:
      ""
    case q <> Nil{}:
      question_to_json(q)
    case q <> rest:
      question_to_json(q) ++ "," ++ questions_to_json(rest)

# Build complete TypeSafe System One request JSON
def build_classify_payload(state: String, qs: List<&2, Question>) -> String:
  "{\"state\":\"" ++ json_escape(state) ++ "\",\"model\":\"jev-latest\",\"questions\":{" ++ questions_to_json(qs) ++ "}}"

# ------------------------------------------------------------------------------
# The Classify Primitive
# ------------------------------------------------------------------------------
# Classify takes the current agent state and a list of typed questions.
# It dispatches them to TypeSafe System One in a single parallel call,
# returning the structured JSON result directly.
def Classify(state: String, questions: List<&2, Question>) -> IO(String):
  do IO<String>:
    payload : String <- IO.pure(String, build_classify_payload(state, questions))
    typesafe.post(payload)

# ------------------------------------------------------------------------------
# The Generate Primitive
# ------------------------------------------------------------------------------
# Build OpenAI-compatible chat completion payload
def build_generate_payload(model: String, system_prompt: String, prompt: String) -> String:
  "{\"model\":\"" ++ json_escape(model) ++ "\",\"messages\":[{\"role\":\"system\",\"content\":\"" ++ json_escape(system_prompt) ++ "\"},{\"role\":\"user\",\"content\":\"" ++ json_escape(prompt) ++ "\"}]}"

# Generate takes a model identifier, system prompt, and user prompt.
# It dispatches the request to OpenRouter (or configured OpenAI-compatible endpoint).
def Generate(model: String, system_prompt: String, prompt: String) -> IO(String):
  do IO<String>:
    payload : String <- IO.pure(String, build_generate_payload(model, system_prompt, prompt))
    openrouter.post(payload)

# ------------------------------------------------------------------------------
# Demonstration / Test
# ------------------------------------------------------------------------------
def agent_state() -> String:
  "Compiler error in file 'agent.c': undefined reference to symbol 'curl_easy_init'. Build aborted with code 1. User wants to fix the build immediately."

def agent_questions() -> List<&2, Question>:
  [
    ChoiceQ{
      "next_action",
      "What is the best immediate action for the agent to take to resolve this error?",
      [
        Opt{"add_dependency", "Add missing link library like -lcurl to compiler flags or build script"},
        Opt{"rewrite_code", "Rewrite the source code to remove or rename curl functions"},
        Opt{"ask_user", "Stop and ask the user for clarification"},
        Opt{"ignore_error", "Ignore error and continue"}
      ]
    },
    NoulQ{
      "is_fatal_blocker",
      "Does this build failure block progress and require immediate resolution?"
    },
    ScoreQ{
      "fix_complexity",
      "Estimate the complexity of fixing this linker issue",
      [
        "Trivial: 1-line flag or install fix",
        "Moderate: build configuration adjustments",
        "Complex: major architectural changes"
      ]
    }
  ]

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("==================================================")
    IO.print("Bender Agent Primitives: Classify & Generate")
    IO.print("==================================================")
    IO.print("1. AGENT STATE:")
    IO.print(agent_state())
    IO.print("")
    IO.print("2. RUNNING CLASSIFY (TypeSafe System One)...")
    c_resp : String <- Classify(agent_state(), agent_questions())
    IO.print("Classify Decision:")
    IO.print(c_resp)
    IO.print("")
    IO.print("3. RUNNING GENERATE (OpenRouter / LLM)...")
    g_resp : String <- Generate(
      "google/gemma-4-26b-a4b-it:free",
      "You are an expert systems programmer. Provide a concise 1-2 sentence solution to the reported compiler/linker error.",
      "Fix this compiler error: undefined reference to symbol 'curl_easy_init'. Show the exact compiler command."
    )
    IO.print("Generate Output:")
    IO.print(g_resp)
    IO.print("==================================================")
