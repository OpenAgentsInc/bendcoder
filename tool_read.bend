import Base

# ==============================================================================
# tool_read's pure half: split, select, render
# ==============================================================================
# Only reading the bytes is IO — sys.read_raw (sys_c.c) keeps the stat checks,
# the 256 KB cap and the BOM strip, which need the file's size and its bytes.
# Everything downstream is a pure String -> String and lives here, where the
# properties are laws rather than the four examples test_tools.c pins:
#
#   * the emitted line count is min(limit, lines - offset) — Read.page_count
#   * stripping the rendered "N\t" prefixes returns the lines unchanged —
#     Read.strip_*, the round-trip Edit's fallback has depended on since #7
#
# tool_read in tools_c.h is the C mirror of render() for bendcoder_agent.c;
# keep them in step.
# ==============================================================================

# ------------------------------------------------------------------------------
# Lines, selected
# ------------------------------------------------------------------------------
# String.split on '\n' is the source algorithm's rule: a trailing newline
# yields a final empty line, so "a\n" counts as two lines.

# The lines a read emits: drop `off` lines (the 0-based offset), then take
# `lim` — a `lim` of 0 reads to the end of the file.
def page(ls: List<&2, String>, off: Nat, lim: Nat) -> List<&2, String>:
  match lim:
    case 0n:
      List.drop(&2, String, ls, off)
    case 1n+p:
      List.take(&2, String, List.drop(&2, String, ls, off), 1n+p)

# ------------------------------------------------------------------------------
# Lines, rendered as "N\tline"
# ------------------------------------------------------------------------------
# A '\r' before a '\n' belongs to the line ending, not the line (CRLF).
def chomp_cr.go(line: String, ends_cr: Bool) -> String:
  match ends_cr:
    case True{}:
      String.reverse(String.drop(String.reverse(line), 1n))
    case False{}:
      line

def chomp_cr(+line: String) -> String:
  chomp_cr.go(line, String.ends_with(line, "\r"))

# One rendered line: the absolute 1-indexed number, a tab, the text.
def render_line(no: U32, +line: String) -> String:
  U32.show(no) ++ "\t" ++ chomp_cr(line)

# The selected lines with their absolute numbers, starting at off + 1.
def numbered.go(ls: List<&2, String>, +no: U32) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case h <> t:
      render_line(no, h) <> numbered.go(t, U32.inc(no))

def numbered(ls: List<&2, String>, off: Nat) -> List<&2, String>:
  numbered.go(ls, U32.inc(U32.from_nat(off)))

# ------------------------------------------------------------------------------
# The pure function downstream of the bytes
# ------------------------------------------------------------------------------
def empty_warn() -> String:
  "<system-reminder>Warning: the file exists but the contents are empty.</system-reminder>"

# `off` is the 0-based drop; the warning shows the 1-indexed offset it came
# from and the file's real line count.
def short_warn(off: Nat, total: Nat) -> String:
  "<system-reminder>Warning: the file exists but is shorter than the provided offset (" ++
    Nat.show(Nat.add(off, 1n)) ++ "). The file has " ++ Nat.show(total) ++
    " lines.</system-reminder>"

# `none` is "the page selected no lines", computed by the caller — a match
# scrutinizes parameters only.
def render.emitted(none: Bool, lines: List<&2, String>, +off: Nat, lim: Nat) -> String:
  match none:
    case True{}:
      short_warn(off, List.length(&2, String, lines))
    case False{}:
      String.join(numbered(page(lines, off, lim), off), "\n")

def render.body(+content: String, offset: U32, limit: U32) -> String:
  +lines = String.lines(content)
  +off = Nat.sub(U32.to_nat(offset), 1n)
  +lim = U32.to_nat(limit)
  render.emitted(List.is_empty(&2, String, page(lines, off, lim)), lines, off, lim)

def render.empty(empty: Bool, content: String, offset: U32, limit: U32) -> String:
  match empty:
    case True{}:
      empty_warn()
    case False{}:
      render.body(content, offset, limit)

# `content` as sys.read_raw returns it: post-BOM-strip, pre-split. `offset`
# is the first line to emit (0 and 1 both mean line 1); `limit` 0 reads to
# the end of the file.
def render(+content: String, offset: U32, limit: U32) -> String:
  render.empty(String.is_empty(content), content, offset, limit)

# ------------------------------------------------------------------------------
# The count law: how many lines a page emits
# ------------------------------------------------------------------------------
# pmin is min spelled for the checker: Nat.min routes through is_lt's Bool,
# which stays stuck on symbolic input, while this recurses on the numbers
# themselves — which is what lets the proofs below reduce one Succ per case.
def pmin(a: Nat, b: Nat) -> Nat:
  match a b:
    case 0n _:
      0n
    case _ 0n:
      0n
    case 1n+x 1n+y:
      1n+pmin(x, y)

# The spec the count law is read against: for a `total`-line file, an `off`
# drop and a `lim` take (0 = to the end), this many lines are emitted —
# min(limit, total - offset) in the issue's terms, with offset 0-based here.
def page_spec(total: Nat, off: Nat, lim: Nat) -> Nat:
  match lim:
    case 0n:
      Nat.sub(total, off)
    case 1n+lp:
      pmin(1n+lp, Nat.sub(total, off))

# LAW: taking n lines yields min(n, len). Spec-first so the page proof can
# rewrite the implementation side of its goal.
law Read.len_take:
  for ls: List<&2, String>
  for n: Nat
  {pmin(n, List.length(&2, String, ls)) ==
   List.length(&2, String, List.take(&2, String, ls, n)) : Nat}

def Read.len_take(ls, n):
  match ls n:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+np:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+np:
      %Read.len_take(t, np) : {1n+pmin(np, List.length(&2, String, t)) == 1n+_ : Nat}
      {==}

# LAW: dropping n lines leaves len - n, saturating at 0.
law Read.len_drop:
  for ls: List<&2, String>
  for n: Nat
  {Nat.sub(List.length(&2, String, ls), n) ==
   List.length(&2, String, List.drop(&2, String, ls, n)) : Nat}

def Read.len_drop(ls, n):
  match ls n:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+np:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+np:
      %Read.len_drop(t, np) : {Nat.sub(List.length(&2, String, t), np) == _ : Nat}
      {==}

# LAW: the rendered line count is min(limit, total - offset) — limit 0 reads
# to the end. The issue's first property, over every input rather than the
# four offsets test_tools.c tries.
law Read.page_count:
  for ls: List<&2, String>
  for off: Nat
  for lim: Nat
  {page_spec(List.length(&2, String, ls), off, lim) ==
   List.length(&2, String, page(ls, off, lim)) : Nat}

def Read.page_count(ls, off, lim):
  match ls off:
    case Nil{} 0n:
      match lim:
        case 0n:
          {==}
        case 1n+lp:
          {==}
    case Nil{} 1n+op:
      match lim:
        case 0n:
          {==}
        case 1n+lp:
          {==}
    case h <> +t 0n:
      match lim:
        case 0n:
          Read.len_drop(h <> t, 0n)
        case 1n+lp:
          %Read.len_take(t, lp) : {1n+pmin(lp, List.length(&2, String, t)) == 1n+_ : Nat}
          {==}
    case h <> +t 1n++op:
      match lim:
        case 0n:
          Read.len_drop(h <> t, 1n+op)
        case 1n+lp:
          %Read.len_take(List.drop(&2, String, t, op), 1n+lp) : {pmin(1n+lp, Nat.sub(List.length(&2, String, t), op)) == _ : Nat}
          %Read.len_drop(t, op) : {pmin(1n+lp, Nat.sub(List.length(&2, String, t), op)) == pmin(1n+lp, _) : Nat}
          {==}

# ------------------------------------------------------------------------------
# Stripping the prefixes back off
# ------------------------------------------------------------------------------
# A line's leading "N\t" (Read), "N:" (Grep) or leftover "\t" is metadata the
# model copied back, not content — the C twin is bendcoder_strip_line_prefixes
# in tools_c.h, the fallback Edit's "not found" path runs (#7).
# Bool.pick stands in for the computed-boolean match: a match scrutinizes
# parameters only, and two mutually recursive helpers are a forward reference
# Bend does not allow.
def strip_line.scan(s: String, +orig: String) -> String:
  match s:
    case SNil{}:
      orig
    case SCon{+h, +t}:
      Bool.pick(
        String,
        Bool.or(Char.is_eq(h, '\t'), Char.is_eq(h, ':')),
        t,
        Bool.pick(String, Char.is_digit(h), strip_line.scan(t, orig), orig))

def strip_line.top(+h: Char, +t: String, +orig: String) -> String:
  Bool.pick(
    String,
    Char.is_eq(h, '\t'),
    t,
    Bool.pick(String, Char.is_digit(h), strip_line.scan(t, orig), orig))

def strip_line(+line: String) -> String:
  match line:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      strip_line.top(h, t, SCon{h, t})

def strip_render.cons(line: String, acc: List<&2, String>) -> List<&2, String>:
  +t = strip_line(line)
  t <> acc

# Every line of the rendered text stripped — the shape Edit's fallback
# consumes when a model quotes a read back into old_string.
def strip_render(s: String) -> String:
  String.join(
    List.foldr(~&2, ~String, ~List<&2, String>, ~strip_render.cons,
               String.split(s, '\n'), {Nil{} : List<&2, String>}),
    "\n")

# ------------------------------------------------------------------------------
# The strip laws: the round-trip Edit depends on
# ------------------------------------------------------------------------------
# The rendered prefix is digits then a tab; stripping it returns the line
# unchanged. The prefix is concrete and the body universal — the strongest
# form of the round-trip the checker can decide, since Nat.show of a
# symbolic number never reduces. One, two and three digit prefixes pin the
# scan's recursion.
law Read.strip_digit:
  for line: String
  {strip_line("7\t" ++ line) == line : String}

def Read.strip_digit(line): {==}

law Read.strip_digits:
  for line: String
  {strip_line("42\t" ++ line) == line : String}

def Read.strip_digits(line): {==}

law Read.strip_digits_long:
  for line: String
  {strip_line("256\t" ++ line) == line : String}

def Read.strip_digits_long(line): {==}

# LAW: the "N:" spelling Grep renders strips the same way.
law Read.strip_colon:
  for line: String
  {strip_line("12:" ++ line) == line : String}

def Read.strip_colon(line): {==}

# LAW: a bare leftover tab strips too — the number already dropped.
law Read.strip_bare_tab:
  for line: String
  {strip_line("\t" ++ line) == line : String}

def Read.strip_bare_tab(line): {==}

# LAW: a line that is not prefix-shaped is returned unchanged.
law Read.strip_plain:
  for line: String
  {strip_line("x" ++ line) == "x" ++ line : String}

def Read.strip_plain(line): {==}

# LAW: digits that end on neither a tab nor a colon are content, not a
# prefix — the line is kept whole.
law Read.strip_digits_no_sep:
  for line: String
  {strip_line("9x" ++ line) == "9x" ++ line : String}

def Read.strip_digits_no_sep(line): {==}

# ------------------------------------------------------------------------------
# From the FFI result to the reply
# ------------------------------------------------------------------------------
# sys.read_raw hands the bytes over as Done{content} and the checked failures
# as Fail{(code, message)}; the message is the same "error: ..." text
# tool_read produced, and it is the reply either way.
def finish(r: Result<&1, &1, U32 & String, String>, offset: U32, limit: U32) -> String:
  match r:
    case Done{+content}:
      render(content, offset, limit)
    case Fail{e}:
      (code, text) = e
      text

# ------------------------------------------------------------------------------
# The render, exercised end to end
# ------------------------------------------------------------------------------
def probe(+label: String, out: String) -> IO(Unit):
  do IO<Unit>:
    u : Unit <- IO.print(label)
    IO.print(out)

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- probe("read to EOF:", render("one\ntwo\nthree\n", 1, 0))
    u2 : Unit <- probe("read one line:", render("one\ntwo\nthree\n", 2, 1))
    u3 : Unit <- probe("offset 0 is line 1:", render("one\ntwo\nthree\n", 0, 2))
    u4 : Unit <- probe("offset past EOF:", render("one\ntwo\nthree\n", 5, 2))
    u5 : Unit <- probe("empty file:", render("", 1, 0))
    u6 : Unit <- probe("CRLF:", render("a\r\nb\n", 1, 0))
    u7 : Unit <- probe("strip_render round-trip:", strip_render(render("one\ntwo\nthree\n", 1, 0)))
    probe("strip_render mixed:", strip_render("1\tone\nx\n\ty"))

#|read to EOF:
#|1	one
#|2	two
#|3	three
#|4	
#|read one line:
#|2	two
#|offset 0 is line 1:
#|1	one
#|2	two
#|offset past EOF:
#|<system-reminder>Warning: the file exists but is shorter than the provided offset (5). The file has 4 lines.</system-reminder>
#|empty file:
#|<system-reminder>Warning: the file exists but the contents are empty.</system-reminder>
#|CRLF:
#|1	a
#|2	b
#|3	
#|strip_render round-trip:
#|one
#|two
#|three
#|
#|strip_render mixed:
#|one
#|x
#|y
