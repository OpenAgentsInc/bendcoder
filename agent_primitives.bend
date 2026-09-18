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

# Base's List.map only covers List<&1, _>; this is the List<&2, _> (Data)
# variant, built on List.foldr. The +t let hands the computed element to the
# cons as a reusable value, which a &2 list cell requires.
def map_data_cons(~A: Data, ~B: Data, ~f: A -> B, x: A, acc: List<&2, B>) -> List<&2, B>:
  +t = f(x)
  t <> acc

def map_data(~A: Data, ~B: Data, ~f: A -> B, xs: List<&2, A>) -> List<&2, B>:
  List.foldr(~&2, ~A, ~List<&2, B>, ~map_data_cons(~A, ~B, ~f), xs, {Nil{} : List<&2, B>})

# Serialize one Choice option into a "label":"description" JSON map entry
def choice_option_to_json(o: OptionPair) -> String:
  match o:
    case Opt{label, desc}:
      "\"" ++ json_escape(label) ++ "\":\"" ++ json_escape(desc) ++ "\""

# Serialize Choice options into JSON map
def choice_options_to_json(opts: List<&2, OptionPair>) -> String:
  String.join(map_data(~OptionPair, ~String, ~choice_option_to_json, opts), ",")

# Serialize one rubric level into a JSON string
def rubric_item_to_json(item: String) -> String:
  "\"" ++ json_escape(item) ++ "\""

# Serialize Score rubric into JSON array
def score_rubric_to_json(rubric: List<&2, String>) -> String:
  String.join(map_data(~String, ~String, ~rubric_item_to_json, rubric), ",")

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
  String.join(map_data(~Question, ~String, ~question_to_json, qs), ",")

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
