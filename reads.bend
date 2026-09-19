import Base

# ==============================================================================
# reads.bend: the loop's read bookkeeping — per-file cursors, the pending read
# a refused edit names, and the Book that carries them between steps
# ==============================================================================
# bendcoder_agent.c keeps this in globals: read_cursors[], pending_read and
# search_miss_run. Bend has no globals, so the same record travels inside the
# loop's Progress as a typed value: the Book is the loop's side-state, handed
# to each handler and handed back with whatever it changed.
# ------------------------------------------------------------------------------

# One file's cursor: `next` is the 1-indexed line the next read serves;
# `done` marks a file read to the end, which drops it out of the read
# picker's options (bendcoder_agent.c's exhausted flag).
type ReadMark is Data:
  Rd{path: String, next: U32, done: Bool}

# The loop's side-state. `misses` counts consecutive failed searches — the
# deterministic record of a search_code that keeps failing, since nothing
# else notices it. `reads` is the per-file cursor table. `want` is the file
# a refused blind edit named for the next read (#35's mechanism). `read_once`
# is whether any read_code has run, which is what the route's "only drafted
# against code already read" guard tests — bendcoder_agent.c's read_phase != 0.
# `low` counts consecutive under-floor decisions that rerouted — the run the
# floor's spent check and the flail halt both read. bendcoder_agent.c's
# low_confidence_run.
type Book is Data:
  Bk{
    misses: U32,
    reads: List<&2, ReadMark>,
    want: Maybe<&2, String>,
    read_once: Bool,
    low: U32
  }

def book.new() -> Book:
  Bk{0, {Nil{} : List<&2, ReadMark>}, None{}, False{}, 0}

# The consecutive-miss run a non-search report always ends.
def book_acted(+b: Book) -> Book:
  match b:
    case Bk{misses, +reads, +want, +ro, +low}:
      Bk{0, reads, want, ro, low}

# A missed search: the run grows by one, the rest of the book untouched.
def book_missed(+b: Book) -> Book:
  match b:
    case Bk{+misses, +reads, +want, +ro, +low}:
      Bk{U32.inc(misses), reads, want, ro, low}

# A refused blind edit names the file it needed: the next read serves it
# rather than asking again — pending_read in bendcoder_agent.c.
def book_want(+b: Book, +path: String) -> Book:
  match b:
    case Bk{misses, +reads, want, +ro, +low}:
      Bk{0, reads, Some{path}, ro, low}

# The marks, for the read picker's done set and the blind-edit guard's
# read_cursor_find.
def book_marks(+b: Book) -> List<&2, ReadMark>:
  match b:
    case Bk{misses, +reads, want, ro, low}:
      reads

# The flail counter: a decision under its consequence-weighted floor that
# rerouted bumps it; a confident decision — or one the spent floor let act —
# clears it. low_confidence_run in bendcoder_agent.c.
def book_tally(+b: Book, under: Bool) -> Book:
  match b under:
    case Bk{+misses, +reads, +want, +ro, +l} True{}:
      Bk{misses, reads, want, ro, U32.inc(l)}
    case Bk{+misses, +reads, +want, +ro, l} False{}:
      Bk{misses, reads, want, ro, 0}

# Consecutive under-floor decisions the loop tolerates before it stops —
# BENDCODER_MAX_LOW_CONFIDENCE. Kept beside the counter it compares against.
def low_limit() -> U32: 3

# Enough consecutive under-floor decisions to stop rather than flail —
# the caller's `under` is this step's, so the check sees the run including it.
def book_flailing(+b: Book, under: Bool) -> Bool:
  match b under:
    case Bk{misses, reads, want, ro, +l} True{}:
      U32.is_ge(U32.inc(l), low_limit())
    case _ _:
      False{}

# The under-floor reroutes the floor buys before it is spent. Two reads is
# what a cautious loop needs around a decision it distrusts; a third reroute
# reads into files that stopped being able to help, so the guarded path takes
# the decision instead. Read by the caller before this step's tally.
def floor_reads() -> U32: 2

# Whether the floor already bought its reads — `low` at this decision, not
# including it, so the second consecutive reroute spends the floor and the
# third under-floor decision acts.
def book_spent(+b: Book) -> Bool:
  match b:
    case Bk{misses, reads, want, ro, +l}:
      U32.is_ge(l, floor_reads())

# "the head of xs is a mark for path" — the computed scrutinee the walks
# below receive as a parameter, because a match cannot inspect the call.
def rd_eq(+m: ReadMark, +path: String) -> Bool:
  match m:
    case Rd{+p, next, done}:
      String.eq(p, path)

def rd_head(+xs: List<&2, ReadMark>, +path: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      rd_eq(h, path)

# The mark for a path, when one exists.
def rd_find.go(+xs: List<&2, ReadMark>, +path: String, hit: Bool) -> Maybe<&2, ReadMark>:
  match xs hit:
    case Nil{} _:
      None{}
    case +h <> t True{}:
      Some{h}
    case h <> t False{}:
      rd_find.go(t, path, rd_head(t, path))

def rd_find(+path: String, +xs: List<&2, ReadMark>) -> Maybe<&2, ReadMark>:
  rd_find.go(xs, path, rd_head(xs, path))

# Insert or replace the mark for a path, in place.
def rd_put.go(+xs: List<&2, ReadMark>, +path: String, next: U32, done: Bool, hit: Bool) -> List<&2, ReadMark>:
  match xs hit:
    case Nil{} _:
      [Rd{path, next, done}]
    case h <> t True{}:
      Rd{path, next, done} <> t
    case +h <> t False{}:
      h <> rd_put.go(t, path, next, done, rd_head(t, path))

def rd_put(+xs: List<&2, ReadMark>, +path: String, next: U32, done: Bool) -> List<&2, ReadMark>:
  rd_put.go(xs, path, next, done, rd_head(xs, path))

def rd_off(+m: ReadMark) -> U32:
  match m:
    case Rd{path, +next, done}:
      next

# The line the next read of path serves: its cursor's `next`, or 1 when the
# file was never served — the read_cursor_for(.., next_line = 1) default.
def rd_next.of(m: Maybe<&2, ReadMark>) -> U32:
  match m:
    case Some{+r}:
      rd_off(r)
    case None{}:
      1

def rd_next(+xs: List<&2, ReadMark>, +path: String) -> U32:
  rd_next.of(rd_find(path, xs))

# The paths read to the end — the set the read picker's options exclude.
def rd_done.push(acc: List<&2, String>, m: ReadMark) -> List<&2, String>:
  match m:
    case Rd{+p, next, done}:
      match done:
        case True{}:
          p <> acc
        case False{}:
          acc

def rd_done(+xs: List<&2, ReadMark>) -> List<&2, String>:
  List.reverse(&2, String,
    List.foldl(~&2, ~ReadMark, ~List<&2, String>, ~rd_done.push, xs, {Nil{} : List<&2, String>}))

# Whether a string occurs in a list — List.contains over String.eq.
def str_member(+xs: List<&2, String>, +s: String) -> Bool:
  List.contains(~String, ~String.eq, xs, s)

# A page served: the cursor advances or the file is marked done, read_once
# sets, the pending read clears, and the miss run ends — read_code is not
# search_code, and pending_read clears before the page serves in C.
def book_served(+b: Book, +path: String, next: U32, done: Bool) -> Book:
  match b:
    case Bk{misses, +reads, want, ro, +low}:
      Bk{0, rd_put(reads, path, next, done), None{}, True{}, low}

# The phase-0 listing+README read serves no tracked page — bendcoder_agent.c's
# first read creates no cursor — but it still counts as a read for the
# route guards and ends the miss run.
def book_phase0(+b: Book) -> Book:
  match b:
    case Bk{misses, +reads, +want, ro, +low}:
      Bk{0, reads, want, True{}, low}

# The anchor path reads its target in full: a mark set to done, the
# blind-edit guard's intent met and the read picker stops offering it.
def book_exhaust(+b: Book, +path: String, next: U32) -> Book:
  match b:
    case Bk{misses, +reads, +want, ro, +low}:
      Bk{0, rd_put(reads, path, next, True{}), want, ro, low}

# Enough consecutive search misses to turn a search into a read —
# BENDCODER_SEARCH_MISS_LIMIT. Kept beside the counter it compares against.
def miss_limit() -> U32: 2

# The deterministic sibling of the `repeats` Noul: a search that keeps
# missing is not converging, and a read can only add information.
def book_stuck(+b: Book) -> Bool:
  match b:
    case Bk{+misses, reads, want, ro, low}:
      U32.is_ge(misses, miss_limit())

# Whether no read_code has run yet — read_phase == 0 in the C loop, which is
# what the "only drafted against code already read" guard rows test.
def book_unread(+b: Book) -> Bool:
  match b:
    case Bk{misses, reads, want, +ro, low}:
      Bool.not(ro)

# Whether a mark exists for path — read_cursor_find's "was it read at all",
# which read_cursor_for cannot answer since it always returns one.
def rd_has.of(m: Maybe<&2, ReadMark>) -> Bool:
  match m:
    case Some{r}:
      True{}
    case None{}:
      False{}

def rd_has(+xs: List<&2, ReadMark>, +path: String) -> Bool:
  rd_has.of(rd_find(path, xs))

# ------------------------------------------------------------------------------
# The coverage manifest: run_tests.sh ends with one "COVERED: <path>" line per
# file it exercises, so a green run over a file absent from the list is the
# weaker thing it is rather than verification (#22). suite_covers in
# bendcoder_agent.c answers with three states, and so does this.
# ------------------------------------------------------------------------------
type Cover is Data:
  # No "COVERED: " line at all — whether the suite exercises the file is unknown.
  CUnknown{}
  # A manifest exists and the path is not in it.
  CAbsent{}
  # The manifest names the path.
  CCovered{}

def cover_check(manifest: Bool, named: Bool) -> Cover:
  match manifest named:
    case False{} _:
      CUnknown{}
    case True{} False{}:
      CAbsent{}
    case True{} True{}:
      CCovered{}

# The manifest check itself, on the verification output and the edited path.
# The trailing newline in the needle is what stops a path's prefix naming a
# longer file as covered ("COVERED: tools_c" does not cover tools_c.h).
def suite_cover(+out: String, +path: String) -> Cover:
  cover_check(
    String.contains(out, "COVERED: "),
    String.contains(out, "COVERED: " ++ path ++ "\n"))

# ------------------------------------------------------------------------------
# The helpers, exercised
# ------------------------------------------------------------------------------
def show_mark(+m: ReadMark) -> String:
  match m:
    case Rd{+p, +n, +d}:
      p ++ ":" ++ U32.show(n) ++ Bool.pick(String, d, " done", "")

def map_marks.cons(m: ReadMark, acc: List<&2, String>) -> List<&2, String>:
  +s = show_mark(m)
  s <> acc

def map_marks(+xs: List<&2, ReadMark>) -> List<&2, String>:
  List.foldr(~&2, ~ReadMark, ~List<&2, String>, ~map_marks.cons, xs, {Nil{} : List<&2, String>})

def show_marks(+xs: List<&2, ReadMark>) -> String:
  String.join(map_marks(xs), " | ")

def show_find(m: Maybe<&2, ReadMark>) -> String:
  match m:
    case Some{+r}:
      show_mark(r)
    case None{}:
      "none"

def show_cover(c: Cover) -> String:
  match c:
    case CUnknown{}:
      "unknown"
    case CAbsent{}:
      "absent"
    case CCovered{}:
      "covered"

def main() -> IO(Unit):
  do IO<Unit>:
    +m0 : List<&2, ReadMark> = {Nil{} : List<&2, ReadMark>}
    +m1 : List<&2, ReadMark> = rd_put(m0, "a.c", 201, False{})
    u1 : Unit <- IO.print("insert -> " ++ show_marks(m1))
    +m2 : List<&2, ReadMark> = rd_put(m1, "b.c", 1, False{})
    +m3 : List<&2, ReadMark> = rd_put(m2, "a.c", 401, False{})
    u2 : Unit <- IO.print("advance in place -> " ++ show_marks(m3))
    +m4 : List<&2, ReadMark> = rd_put(m3, "b.c", 300, True{})
    u3 : Unit <- IO.print("exhausted -> " ++ show_marks(m4))
    u4 : Unit <- IO.print("find a.c -> " ++ show_find(rd_find("a.c", m4)))
    u5 : Unit <- IO.print("find z.c -> " ++ show_find(rd_find("z.c", m4)))
    u6 : Unit <- IO.print("next a.c -> " ++ U32.show(rd_next(m4, "a.c")))
    u7 : Unit <- IO.print("next z.c -> " ++ U32.show(rd_next(m4, "z.c")))
    u8 : Unit <- IO.print("done -> " ++ String.join(rd_done(m4), ","))
    u9 : Unit <- IO.print("member -> " ++ Bool.pick(String, str_member(["a", "b"], "b"), "yes", "no"))
    u10 : Unit <- IO.print("nonmember -> " ++ Bool.pick(String, str_member(["a", "b"], "z"), "yes", "no"))
    u11 : Unit <- IO.print("stuck 2 -> " ++ Bool.pick(String, book_stuck(Bk{2, m4, None{}, True{}, 0}), "yes", "no"))
    u12 : Unit <- IO.print("stuck 1 -> " ++ Bool.pick(String, book_stuck(Bk{1, m4, None{}, True{}, 0}), "yes", "no"))
    u13 : Unit <- IO.print("unread -> " ++ Bool.pick(String, book_unread(book.new()), "yes", "no"))
    u14 : Unit <- IO.print("read -> " ++ Bool.pick(String, book_unread(Bk{0, m4, None{}, True{}, 0}), "yes", "no"))
    u15 : Unit <- IO.print("has a.c -> " ++ Bool.pick(String, rd_has(m4, "a.c"), "yes", "no"))
    u16 : Unit <- IO.print("has z.c -> " ++ Bool.pick(String, rd_has(m4, "z.c"), "yes", "no"))
    +b1 : Book = book_want(book.new(), "a.c")
    +b2 : Book = book_served(b1, "a.c", 201, False{})
    u17 : Unit <- IO.print("served -> " ++ show_marks(book_marks(b2)) ++ " | unread " ++ Bool.pick(String, book_unread(b2), "yes", "no"))
    +b3 : Book = book_tally(Bk{0, m4, None{}, True{}, 2}, True{})
    u18 : Unit <- IO.print("flail 3 -> " ++ Bool.pick(String, book_flailing(b3, True{}), "yes", "no"))
    u19 : Unit <- IO.print("flail calm -> " ++ Bool.pick(String, book_flailing(Bk{0, m4, None{}, True{}, 2}, False{}), "yes", "no"))
    u23 : Unit <- IO.print("spent 2 -> " ++ Bool.pick(String, book_spent(Bk{0, m4, None{}, True{}, 2}), "yes", "no"))
    u24 : Unit <- IO.print("spent 1 -> " ++ Bool.pick(String, book_spent(Bk{0, m4, None{}, True{}, 1}), "yes", "no"))
    +cov : String = "== suite coverage ==\nCOVERED: README.md\nCOVERED: tools_c.h\nAll checks passed.\n"
    u20 : Unit <- IO.print("covered -> " ++ show_cover(suite_cover(cov, "tools_c.h")))
    u21 : Unit <- IO.print("absent -> " ++ show_cover(suite_cover(cov, "LICENSE")))
    u22 : Unit <- IO.print("prefix -> " ++ show_cover(suite_cover(cov, "tools_c")))
    IO.print("nomanifest -> " ++ show_cover(suite_cover("All checks passed.\n", "tools_c.h")))

#|insert -> a.c:201
#|advance in place -> a.c:401 | b.c:1
#|exhausted -> a.c:401 | b.c:300 done
#|find a.c -> a.c:401
#|find z.c -> none
#|next a.c -> 401
#|next z.c -> 1
#|done -> b.c
#|member -> yes
#|nonmember -> no
#|stuck 2 -> yes
#|stuck 1 -> no
#|unread -> yes
#|read -> no
#|has a.c -> yes
#|has z.c -> no
#|served -> a.c:201 | unread no
#|flail 3 -> yes
#|flail calm -> no
#|spent 2 -> yes
#|spent 1 -> no
#|covered -> covered
#|absent -> absent
#|prefix -> absent
#|nomanifest -> unknown
