import Base
import ./tool_read.bend as T

# ==============================================================================
# Bendcoder Agent Core: Classify & Generate
# ==============================================================================
# In Bendcoder, the agent loop is simplified to two core primitives:
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

# The IO half of Read: the stat checks, the 256 KB cap and the BOM strip,
# which need the file's size and its bytes. Returns Done{content} — the raw
# bytes, BOM already stripped — or Fail{(code, message)} with the "error: ..."
# text. Everything downstream (split, offset/limit, "N\tline") is pure and
# lives in tool_read.bend, where its laws are proved.
law sys.read_raw:
  String -> String -> IO(Result<&1, &1, U32 & String, String>)

def sys.read_raw(path, limit):
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

# "true" or "false" — the blind-edit guard's bendcoder_exists, asked before an
# edit to a file never read is refused.
law sys.exists:
  String -> IO(String)

def sys.exists(path):
  import "./sys_c.c"

# Deletion as an effect: a file the edit created is removed on rollback
# rather than left behind empty, which is what snapshotting nil meant in C.
law sys.remove_file:
  String -> IO(String)

def sys.remove_file(path):
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

# One string as a JSON string literal: quoted and escaped.
def json_str(s: String) -> String:
  "\"" ++ json_escape(s) ++ "\""

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

# Serialize Score rubric into JSON array body
def score_rubric_to_json(rubric: List<&2, String>) -> String:
  String.join(map_data(~String, ~String, ~json_str, rubric), ",")

# A list of strings as a JSON array
def json_str_list(xs: List<&2, String>) -> String:
  "[" ++ String.join(map_data(~String, ~String, ~json_str, xs), ",") ++ "]"

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

# ------------------------------------------------------------------------------
# The structured state (design rule 3)
# ------------------------------------------------------------------------------
# Classify sends `state` as a JSON object with named fields rather than one
# hand-escaped string of "[label]:" sections. A question can then point at a
# field with a backticked path -- `observations`, `index.search_hits` -- where
# a blob made a previous attempt indistinguishable from a file's contents.
# This is #14's typed transcript seen from the wire side: when the List<Step>
# lands, `observations` is what it renders into; until then the entries are
# the same "[label]:\nbody" texts the string state carried.
#
# `index` is injected retrieval: retrieval the model must ask for is not
# called, so the repository listing and the searches already run travel in
# every payload rather than behind a tool call.

# The last verification's outcome, rendered "unknown"/"passed"/"failed".
type Verif is Data:
  VUnknown{}
  VPass{}
  VFail{}

type State is Data:
  St{
    directive: String,               # the goal, verbatim
    step: String,                    # the action last run; "" before the first
    steps_done: List<&2, String>,    # actions that ran before `step`, oldest first
    observations: List<&2, String>,  # bounded tool results, newest last
    changed_paths: List<&2, String>, # files an applied edit left changed
    verification: Verif,             # the last verification's outcome
    index_paths: List<&2, String>,   # the repository listing, injected
    search_hits: List<&2, String>,   # the searches already run, injected
    steps_left: U32                  # fuel the loop has left
  }

# The budget the rendered observations must fit, standing where the C
# buffer's 32768 did, and the per-entry clip standing where
# BENDCODER_MAX_TOOL_OUTPUT did. Written as products rather than literals: a Nat
# is unary, so 32768n expands to that many constructors at check time and
# overflows the machine stack.
def state_budget() -> Nat: Nat.mul(256n, 128n)
def entry_budget() -> Nat: Nat.mul(60n, 100n)

# `over` is the computed length check arriving as a parameter, because a match
# cannot scrutinize a computed value — the same split every bounded walk in
# this codebase takes.
def clip.of(+body: String, over: Bool) -> String:
  match over:
    case True{}:
      String.take(body, entry_budget()) ++ "\n... (output truncated)"
    case False{}:
      body

def clip(+body: String) -> String:
  clip.of(body, Nat.is_gt(String.length(body), entry_budget()))

# Whether the head of xs clips inside `room` — computed before the walk's
# match can see it, because a match cannot scrutinize the comparison itself.
# The head is clipped twice (here and in the kept case); at agent scale the
# second clip costs nothing.
def bound.head_fits(xs: List<&2, String>, room: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Nat.is_le(String.length(clip(h)), room)

# Walks a newest-first list keeping what fits in `room` and counting what it
# drops. `keep` is the caller's answer to bound.head_fits for xs's head: an
# entry that does not fit ends the walk, and it plus every entry older than
# it is the deliberate drop. Entries cons onto the front of acc as they are
# met, so acc ends oldest-first — chronological order — without a reverse.
def bound.go(
  xs: List<&2, String>, keep: Bool, acc: List<&2, String>, room: Nat
) -> List<&2, String> & Nat:
  match xs keep:
    case _ False{}:
      (acc, List.length(&2, String, xs))
    case Nil{} _:
      (acc, 0n)
    case +h <> +t True{}:
      +e = clip(h)
      +room2 = Nat.sub(room, String.length(e))
      bound.go(t, bound.head_fits(t, room2), e <> acc, room2)

# The count of dropped entries, said out loud as the first element: a run
# whose observations overflowed the budget is visible in the state itself.
def bound.fin.drop(+acc: List<&2, String>, d: Nat) -> List<&2, String>:
  match d:
    case 0n:
      acc
    case 1n+p:
      ("..." ++ Nat.show(1n+p) ++ " earlier entr(ies) dropped to fit the state budget ...") <> acc

# The pair from the walk is opened here rather than at the call, where the
# destructure would read as a match on the computed call.
def bound.fin(accd: List<&2, String> & Nat) -> List<&2, String>:
  (acc, d) = accd
  bound.fin.drop(acc, d)

# The bounded form of a newest-last list at an explicit budget — split from
# `bound` so the suite can exercise the drop without building 32 KB of text.
def bound.with(+xs: List<&2, String>, +budget: Nat) -> List<&2, String>:
  +rev = List.reverse(&2, String, xs)
  bound.fin(bound.go(
    rev, bound.head_fits(rev, budget), {Nil{} : List<&2, String>}, budget))

def bound(+xs: List<&2, String>) -> List<&2, String>:
  bound.with(xs, state_budget())

def verif_str(v: Verif) -> String:
  match v:
    case VUnknown{}:
      "unknown"
    case VPass{}:
      "passed"
    case VFail{}:
      "failed"

# The whole record rendered to the request's `state` object — the shape the
# selector design gives it, so each question's backticked path names a real
# field. `index.paths` is capped at the Choice option cap: a listing longer
# than that could not be offered as options anyway.
def state_to_json(s: State) -> String:
  match s:
    case St{+directive, +step, +done, +obs, +changed, verification, +paths, +hits, +left}:
      "{\"directive\":" ++ json_str(directive)
        ++ ",\"program\":{\"step\":" ++ json_str(step)
        ++ ",\"steps_done\":" ++ json_str_list(done) ++ "}"
        ++ ",\"observations\":" ++ json_str_list(bound(obs))
        ++ ",\"facts\":{\"changed_paths\":" ++ json_str_list(changed)
        ++ ",\"verification\":" ++ json_str(verif_str(verification)) ++ "}"
        ++ ",\"index\":{\"paths\":" ++ json_str_list(List.take(&2, String, paths, 255n))
        ++ ",\"search_hits\":" ++ json_str_list(bound(hits)) ++ "}"
        ++ ",\"budget\":{\"steps_left\":" ++ U32.show(left) ++ "}}"

# The text form the generative model still gets — Classify reads the object,
# but Generate's prompts want prose, which is the directive plus the
# observations exactly as the old string state concatenated them.
def state_text(s: State) -> String:
  match s:
    case St{+directive, step, done, +obs, changed, verification, paths, hits, left}:
      directive ++ String.concat(obs)

# The injected repository listing in the shape the anchor's file Choice
# already consumes — one path per line.
def state_listing(s: State) -> String:
  match s:
    case St{directive, step, done, obs, changed, verification, +paths, hits, left}:
      String.join(paths, "\n")

# Whether the last recorded verification failed — the signal that a proposed
# apply_edit is a retry informed by an error already in the state rather than
# a fresh uninformed draft.
def state_verify_failed.go(+v: Verif) -> Bool:
  match v:
    case VFail{}:
      True{}
    case _:
      False{}

def state_verify_failed(s: State) -> Bool:
  match s:
    case St{directive, step, done, obs, changed, +verification, paths, hits, left}:
      state_verify_failed.go(verification)

# Whether the program already ran the named action — the final_answer flag
# bendcoder_agent.c keeps beside its state, which the end-of-fuel answer force
# tests before overriding the route.
def state_did(s: State, +name: String) -> Bool:
  match s:
    case St{directive, +step, +done, obs, changed, verification, paths, hits, left}:
      Bool.or(String.eq(step, name), List.contains(~String, ~String.eq, done, name))

# The state a run starts with: the goal as directive, the injected listing as
# index.paths, and everything else at its empty or "unknown" initial value.
def state.new(+directive: String, +paths: List<&2, String>, +left: U32) -> State:
  St{directive, "", Nil{}, Nil{}, Nil{}, VUnknown{}, paths, Nil{}, left}

# Build complete TypeSafe System One request JSON
def build_classify_payload(state: State, qs: List<&2, Question>) -> String:
  "{\"state\":" ++ state_to_json(state) ++ ",\"model\":\"jev-1.13.0\",\"questions\":{" ++ questions_to_json(qs) ++ "}}"

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
def Classify(state: State, questions: List<&2, Question>) -> IO(String):
  do IO<String>:
    payload : String <- IO.pure(String, build_classify_payload(state, questions))
    typesafe.post(payload)

# ------------------------------------------------------------------------------
# The Generate Primitive
# ------------------------------------------------------------------------------
# Build OpenAI-compatible chat completion payload
def build_generate_payload(model: String, system_prompt: String, prompt: String) -> String:
  "{\"model\":\"" ++ json_escape(model) ++ "\",\"store\":false,\"messages\":[{\"role\":\"system\",\"content\":\"" ++ json_escape(system_prompt) ++ "\"},{\"role\":\"user\",\"content\":\"" ++ json_escape(prompt) ++ "\"}]}"

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
# sys.read_raw delivers the bytes and the checked failures; tool_read.bend's
# finish() applies the pure split/select/render or relays the error text.
def Read(path: String, offset: U32, +limit: U32) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- sys.read_raw(path, U32.show(limit))
    IO.pure(String, T.finish(r, offset, limit))

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
# recursively and yields "path:N:line", so a hit can be handed to Read or
# Edit. Hits carry context lines marked "N-line" / "path-N-line", and a miss
# retries case-insensitively before reporting which pieces of the pattern do
# appear and where.
def Grep(pattern: String, path: String) -> IO(String):
  sys.grep_file(pattern, path)

# Whether a path exists on disk — "true"/"false", which the caller compares.
def ExistsFile(path: String) -> IO(String):
  sys.exists(path)

# Delete a file: the rollback of an edit that created it.
def RemoveFile(path: String) -> IO(String):
  sys.remove_file(path)

# ------------------------------------------------------------------------------
# The render, exercised: the object shape and the deliberate drop, pinned
# ------------------------------------------------------------------------------
def demo_state() -> State:
  St{
    "add a greet function",
    "search_code",
    ["read_code"],
    ["[Search for 'greet']:\nhello.bend:4:greet"],
    ["hello.bend"],
    VPass{},
    ["agent_primitives.bend", "hello.bend"],
    ["greet:\nhello.bend:4:greet"],
    5
  }

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(state_to_json(demo_state()))
    IO.print(json_str_list(bound.with(["aaa", "bbb", "ccc"], 4n)))

#|{"directive":"add a greet function","program":{"step":"search_code","steps_done":["read_code"]},"observations":["[Search for 'greet']:\nhello.bend:4:greet"],"facts":{"changed_paths":["hello.bend"],"verification":"passed"},"index":{"paths":["agent_primitives.bend","hello.bend"],"search_hits":["greet:\nhello.bend:4:greet"]},"budget":{"steps_left":5}}
#|["...2 earlier entr(ies) dropped to fit the state budget ...","ccc"]
