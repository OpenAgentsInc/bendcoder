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
# Returns Done{output} on exit 0 and Fail{(code, output)} otherwise, mirroring
# IO.get_env. A plain String would make a passing verification and a failing one
# indistinguishable, which is what blocked the loop from ever rolling back.
law command.run:
  String -> IO(Result<&1, &1, U32 & String, String>)

def command.run(cmd):
  import "./sys_c.c"

law sys.read_file:
  String -> IO(String)

def sys.read_file(path):
  import "./sys_c.c"

law sys.read_lines:
  String -> String -> String -> IO(String)

def sys.read_lines(path, offset, limit):
  import "./sys_c.c"

law sys.write_file:
  String -> String -> IO(String)

def sys.write_file(path, content):
  import "./sys_c.c"

law sys.edit_file:
  String -> String -> String -> String -> IO(String)

def sys.edit_file(path, old_str, new_str, replace_all):
  import "./sys_c.c"

law sys.grep_file:
  String -> String -> IO(String)

def sys.grep_file(pattern, path):
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
# High-Level Classify Answer Definitions
# ------------------------------------------------------------------------------
# The response half of the typed contract: Question is what is asked, Answer is
# what comes back. One ParseAnswer per question id returns a typed value and
# every consumer matches on it, so the positional strstr reads of #27 cannot be
# written. Missing is #32's case — a failed request has no answer, and it used
# to come back as "", which fell through dispatch reading as a decision.
type Answer is Data:
  # A Choice question answered: the label picked and the model's confidence.
  Chosen{choice: String, confidence: F32}
  # A Score question answered: the rubric level and the model's confidence.
  Scored{score: F32, confidence: F32}
  # A Noul question answered: a calibrated probability in [0.0, 1.0].
  Nouled{probability: F32}
  # The request failed, or the response held no usable answer for the id.
  Missing{reason: String}

# Finds one question's object in the response and packs it as the matching
# Answer constructor; anything unrecognised, absent or failed is Missing.
law extract.answer:
  String -> String -> IO(Answer)

def extract.answer(json, qid):
  import "./json_parse_c.c"

def ParseAnswer(json: String, qid: String) -> IO(Answer):
  extract.answer(json, qid)

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

# Lifts the assistant's content out of the OpenAI-compatible chat envelope.
law extract.generation:
  String -> IO(String)

def extract.generation(json):
  import "./json_parse_c.c"

# Generate, with the model's reply lifted out of the OpenRouter envelope.
def GenerateText(model: String, system_prompt: String, prompt: String) -> IO(String):
  do IO<String>:
    raw : String <- Generate(model, system_prompt, prompt)
    extract.generation(raw)

# ------------------------------------------------------------------------------
# The Tool Primitives
# ------------------------------------------------------------------------------
def Exec(cmd: String) -> IO(Result<&1, &1, U32 & String, String>):
  command.run(cmd)

# The FFI boundary is string-only, so the numeric offset/limit and the
# replace_all flag are rendered as text on the way down and parsed in sys_c.c.

# Raw whole-file contents, unnumbered: for handing a file straight to Generate.
def ReadFile(path: String) -> IO(String):
  sys.read_file(path)

# Read: 1-indexed lines rendered as "N\tline". offset is the first line to
# emit (0 and 1 both mean line 1); limit 0 reads to the end of the file.
def Read(path: String, offset: U32, limit: U32) -> IO(String):
  sys.read_lines(path, U32.show(offset), U32.show(limit))

# Write: full write / overwrite, creating any missing parent directories.
# Returns a status line naming the file it created or updated.
def WriteFile(path: String, content: String) -> IO(String):
  sys.write_file(path, content)

# Edit: exact-match search and replace. An old_str matching more than once is
# refused rather than guessed at unless replace_all is set.
def EditFile(path: String, old_str: String, new_str: String) -> IO(String):
  sys.edit_file(path, old_str, new_str, "false")

def EditFileAll(path: String, old_str: String, new_str: String) -> IO(String):
  sys.edit_file(path, old_str, new_str, "true")

# Grep: literal search. A file yields "N:line"; a directory is searched
# recursively and yields "path:N:line", so a hit can be handed to Read or Edit.
def Grep(pattern: String, path: String) -> IO(String):
  sys.grep_file(pattern, path)
