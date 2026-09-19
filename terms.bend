# terms.bend — pure goal-term extraction, ported from the openagents coder's
# terms()/sniff() design (crates/coder/src/repo.rs): the goal's identifier
# terms are grepped into the state before the first model call — retrieval
# the model never has to ask for. Splits the goal on non-identifier
# characters, keeps lowercase words of 3+ chars drawn from [a-z0-9_-], drops
# the stop list, and returns the first 4 distinct survivors in order.
import Base

# One character of an identifier: a letter, a digit, '_' or '-'.
def terms.is_ident_char(+c: Char) -> Bool:
  Bool.or(Char.is_alpha(c),
    Bool.or(Char.is_digit(c),
      Bool.or(Char.is_eq(c, '_'), Char.is_eq(c, '-'))))

# The stop list is data, not code — a literal list checked with
# List.contains, not a Bool.or tree.
def terms.stops() -> List<&2, String>:
  {["the", "and", "for", "are", "how", "what", "does", "this", "that", "with",
    "use", "using", "your", "you", "can", "have", "from", "into", "project",
    "repo", "code", "work", "tell", "show", "describe", "explain", "about",
    "a", "an", "in", "on", "to", "of", "is", "it", "its", "be", "or", "as",
    "at", "by", "do", "not", "no", "if", "but", "so", "up", "out", "why",
    "when", "where", "which", "file", "files", "add", "change", "update",
    "fix", "make", "keeping", "report", "line", "edit", "any", "all", "new",
    "first", "run", "get", "set", "one", "two", "each", "also", "just",
    "like", "should", "would", "could", "need", "needs", "want", "way",
    "them", "then", "than", "these", "those", "our", "we", "i", "me", "my",
    "their", "there", "here", "some", "same", "such", "only", "very", "too",
    "more", "most", "other", "another", "every", "both", "few", "many",
    "much"] : List<&2, String>}

# A word survives at 3+ chars and not on the stop list. The length Bool is
# computed in the call so the helper matches a parameter, not a call.
def terms.keep_word.len(+w: String, long: Bool) -> Bool:
  match long:
    case False{}:
      False{}
    case True{}:
      Bool.not(List.contains(~String, ~String.eq, terms.stops(), w))

def terms.keep_word(+w: String) -> Bool:
  terms.keep_word.len(w, Nat.is_ge(String.length(w), 3n))

def terms.keep(+xs: List<&2, String>, +out: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, out)
    case +w <> t:
      terms.keep(t,
        Bool.pick(List<&2, String>, terms.keep_word(w), w <> out, out))

# A right-fold over the string, String.split's shape with a predicate in the
# separator's place: an identifier char pushes onto the newest word, anything
# else starts a fresh empty one. Empties fall to the length filter, so
# leading, trailing and repeated separators cost nothing.
def terms.split.push(+c: Char, ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      [SCon{c, SNil{}}]
    case h <> t:
      SCon{c, h} <> t

def terms.split.fin(+h: Char, r: List<&2, String>, ident: Bool) -> List<&2, String>:
  match ident:
    case True{}:
      terms.split.push(h, r)
    case False{}:
      SNil{} <> r

def terms.split(s: String) -> List<&2, String>:
  match s:
    case SNil{}:
      {Nil{} : List<&2, String>}
    case SCon{+h, t}:
      terms.split.fin(h, terms.split(t), terms.is_ident_char(h))

# First occurrences win and order is preserved. Bool.pick chooses the next
# accumulators because a match cannot scrutinize the computed contains.
def terms.dedup.go(+xs: List<&2, String>, +seen: List<&2, String>, +out: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      List.reverse(&2, String, out)
    case +h <> t:
      +dup = List.contains(~String, ~String.eq, seen, h)
      terms.dedup.go(t,
        Bool.pick(List<&2, String>, dup, seen, h <> seen),
        Bool.pick(List<&2, String>, dup, out, h <> out))

def terms.dedup(xs: List<&2, String>) -> List<&2, String>:
  terms.dedup.go(xs, {Nil{} : List<&2, String>}, {Nil{} : List<&2, String>})

def terms(+goal: String) -> List<&2, String>:
  List.take(&2, String,
    terms.dedup(terms.keep(terms.split(String.to_lower(goal)), {Nil{} : List<&2, String>})),
    4n)

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print("sniff goal -> [" ++ String.join(terms("Sniff the goal's terms into the initial state"), ",") ++ "]")
    u2 : Unit <- IO.print("stops -> [" ++ String.join(terms("the and for are how what does this that with"), ",") ++ "]")
    u3 : Unit <- IO.print("dedup -> [" ++ String.join(terms("parser parser lexer parser"), ",") ++ "]")
    u4 : Unit <- IO.print("take4 -> [" ++ String.join(terms("alpha beta gamma delta epsilon"), ",") ++ "]")
    u5 : Unit <- IO.print("short -> [" ++ String.join(terms("ab a abc"), ",") ++ "]")
    u6 : Unit <- IO.print("idents -> [" ++ String.join(terms("foo-bar baz_qux"), ",") ++ "]")
    u7 : Unit <- IO.print("case -> [" ++ String.join(terms("UPDATE the Parser"), ",") ++ "]")
    u8 : Unit <- IO.print("empty -> [" ++ String.join(terms(""), ",") ++ "]")
    IO.print("punct -> [" ++ String.join(terms("read_terms() -> list; terms!"), ",") ++ "]")

#|sniff goal -> [sniff,goal,terms,initial]
#|stops -> []
#|dedup -> [parser,lexer]
#|take4 -> [alpha,beta,gamma,delta]
#|short -> [abc]
#|idents -> [foo-bar,baz_qux]
#|case -> [parser]
#|empty -> []
#|punct -> [read_terms,list,terms]
