# base_api.bend — the standard-library digest (#44): base.bend's top-level
# `def`/`type` signature lines, joined across their indented continuations and
# kept only for the namespaces the loop's drafts actually call. run_agent
# injects the list into the state as `index.base_api`, the way `index.paths`
# already travels — the draft prompts then see real names (`String.to_lower`)
# where a model working blind invents them (`String.equals`). Pure: source
# text in, signature list out.
import Base

# The namespaces the digest keeps — measured against what this repository's
# own Bend calls, not the TCP/Chan/File/Map surface an edit here never needs.
def base_api.namespaces() -> List<&2, String>:
  {["String", "List", "Char", "Nat", "U32", "F32", "Bool", "Maybe", "Result",
    "IO"] : List<&2, String>}

# A char inside a signature head's name: letters, digits and '_' — the head
# ends at '.', '(', '<', ' ' or ':'.
def base_api.head_char(+c: Char) -> Bool:
  Bool.or(Char.is_alpha(c), Bool.or(Char.is_digit(c), Char.is_eq(c, '_')))

# The leading name of a signature's name-part: "String.to_lower" -> "String",
# "Maybe<a, ...>" -> "Maybe", "IO(A)" -> "IO".
def base_api.head(+s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, t}:
      Bool.pick(String, base_api.head_char(h), SCon{h, base_api.head(t)}, SNil{})

# A signature line begins at column 0 with `def ` or `type ` — indented
# continuations and bodies never do.
def base_api.sig_start(+line: String) -> Bool:
  Bool.or(String.starts_with(line, "def "), String.starts_with(line, "type "))

# The name onward: "def String.to_lower(...)" -> "String.to_lower(...)".
# Meaningful only where sig_start held; kept() consults it only then.
def base_api.rest_of(+line: String) -> String:
  Bool.pick(String, String.starts_with(line, "def "),
    String.drop(line, 4n), String.drop(line, 5n))

# Kept when the signature's namespace is one the digest carries.
def base_api.kept(+line: String) -> Bool:
  List.contains(~String, ~String.eq, base_api.namespaces(),
    base_api.head(base_api.rest_of(line)))

# A signature is complete once its trimmed text ends in ':' — a trailing '->'
# or a split argument list means indented continuations follow. The same test
# serves an open signature's join: the joined text ends where its last
# appended line ends.
def base_api.closed(+s: String) -> Bool:
  String.ends_with(String.trim(s), ":")

# A pending signature goes on the output when one exists; "" means none was
# open. `out` is newest-first — the walk reverses once at the end.
def base_api.flush(+cur: String, +out: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, String.is_empty(cur), out, cur <> out)

# The head-line properties the walker cannot compute inside a match: whether
# the next line opens a signature, whether its namespace is kept (meaningless
# on a non-signature line, where the walk never consults it), and whether its
# trimmed text closes a signature. Each self-call recomputes all three for the
# line it advances to — the bound.head_fits pattern the observations' budget
# walk already uses.
def base_api.next_start(+ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> t:
      base_api.sig_start(l)

def base_api.next_keep(+ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> t:
      base_api.kept(l)

def base_api.next_done(+ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> t:
      base_api.closed(l)

# The walk itself. `cur`/`open` hold a signature still waiting on its ':';
# start/keep/done are the head line's three properties, computed before entry
# the way every match-on-computed in this codebase is split. A signature line
# flushes whatever was pending, then emits whole when already complete or
# opens for continuations; a non-signature line appends while open and is
# skipped while closed — which also swallows a filtered-out signature's
# continuations, since those never open.
def base_api.digest.go(
  +ls: List<&2, String>, +cur: String, open: Bool, +out: List<&2, String>,
  start: Bool, keep: Bool, done: Bool
) -> List<&2, String>:
  match ls open start keep done:
    case Nil{} _ _ _ _:
      List.reverse(&2, String, base_api.flush(cur, out))
    case l <> +t False{} False{} _ _:
      base_api.digest.go(t, cur, False{}, out,
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))
    case l <> +t True{} False{} _ True{}:
      +cur2 = cur ++ " " ++ String.trim(l)
      base_api.digest.go(t, "", False{}, cur2 <> out,
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))
    case l <> +t True{} False{} _ False{}:
      +cur2 = cur ++ " " ++ String.trim(l)
      base_api.digest.go(t, cur2, True{}, out,
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))
    case l <> +t _ True{} False{} _:
      base_api.digest.go(t, "", False{}, base_api.flush(cur, out),
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))
    case l <> +t _ True{} True{} True{}:
      base_api.digest.go(t, "", False{}, l <> base_api.flush(cur, out),
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))
    case l <> +t _ True{} True{} False{}:
      base_api.digest.go(t, l, True{}, base_api.flush(cur, out),
        base_api.next_start(t), base_api.next_keep(t), base_api.next_done(t))

def digest(+content: String) -> List<&2, String>:
  +ls = String.lines(content)
  base_api.digest.go(ls, "", False{}, {Nil{} : List<&2, String>},
    base_api.next_start(ls), base_api.next_keep(ls), base_api.next_done(ls))

def main() -> IO(Unit):
  do IO<Unit>:
    +src : String = String.join({[
      "# Types",
      "",
      "type Bool is Data:",
      "  False{}",
      "  True{}",
      "def String.to_lower(s: String) -> String:",
      "  s.map(lower)",
      "def TCP.connect(host: String, port: U32) ->",
      "  IO(Result<&1, &1, U32 & String, Socket>):",
      "  import \"./effs/tcp_connect.c\"",
      "def IO.pipe(x: String) ->",
      "  IO(String):",
      "  import \"./effs/pipe.c\"",
      "def Maybe.default(a, -A: Kind(a), m: Maybe<a, A>, d: A) -> A:",
      "type Map<a, -V: Kind(a)> is Kind(a):",
      "def main() -> IO(Unit):"
      ] : List<&2, String>}, "\n")
    u1 : Unit <- IO.print(String.join(digest(src), " | "))
    IO.print(Nat.show(List.length(&2, String, digest(""))))

#|type Bool is Data: | def String.to_lower(s: String) -> String: | def IO.pipe(x: String) -> IO(String): | def Maybe.default(a, -A: Kind(a), m: Maybe<a, A>, d: A) -> A:
#|0
