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

# ------------------------------------------------------------------------------
# Low-level FFI: OpenRouter / LLM Generation
# ------------------------------------------------------------------------------
law openrouter.post:
  String -> IO(String)

def openrouter.post(payload):
  import "./openrouter_c.c"

# ------------------------------------------------------------------------------
# Low-level FFI: Subprocess & File System Tools
# ------------------------------------------------------------------------------
law command.run:
  String -> IO(String)

def command.run(cmd):
  import "./sys_c.c"

law sys.read_file:
  String -> IO(String)

def sys.read_file(path):
  import "./sys_c.c"

law sys.write_file:
  String -> String -> IO(Unit)

def sys.write_file(path, content):
  import "./sys_c.c"

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
# The Tool Primitives
# ------------------------------------------------------------------------------
def Exec(cmd: String) -> IO(String):
  command.run(cmd)

def ReadFile(path: String) -> IO(String):
  sys.read_file(path)

def WriteFile(path: String, content: String) -> IO(Unit):
  sys.write_file(path, content)
