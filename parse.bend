import Base
# guard.bend holds in_repo, the path check parse_edit makes; the laws about it
# are proved in PROOF.bend, which the suite runs separately -- a module with
# unfilled laws cannot be imported by a program.
import ./guard.bend as G

# ==============================================================================
# The Sentinel Edit Parser: what the model's reply becomes
# ==============================================================================
# apply_edit asks the generation model for a sentinel-delimited edit
# (<<<PATH>>> / <<<OLD>>> / <<<NEW>>> / <<<END>>>) rather than JSON, because an
# edit carries exact source text and sentinels survive the quotes, braces and
# newlines a JSON string has to escape. This module turns that reply into a
# typed Edit -- Malformed, Refused, or Block -- so the loop's match is
# exhaustive and a half-applied edit is unrepresentable. Ported from
# do_apply_edit's slicing in bendcoder_agent.c; the laws about the parser land
# with #15.
# ==============================================================================

# ------------------------------------------------------------------------------
# ToolResult: the "error: ..." convention as a type
# ------------------------------------------------------------------------------
# What a tool handed back. Where the C loop string-types the same pair as
# "error: ..." versus anything else, the constructors make the caller's match
# exhaustive instead.
type ToolResult is Data:
  Ok{output: String}
  Err{message: String}

# EditFile and friends report failure as "error: ..." text over the
# string-only FFI; the check is computed here and matched in tool_result.of,
# because a match cannot scrutinize a computed value.
def tool_result.of(failed: Bool, +res: String) -> ToolResult:
  match failed:
    case True{}:
      Err{res}
    case False{}:
      Ok{res}

def tool_result(+res: String) -> ToolResult:
  tool_result.of(String.starts_with(res, "error:"), res)

# ------------------------------------------------------------------------------
# Edit: a drafted edit as parsed from the model's reply
# ------------------------------------------------------------------------------
# The three meaningful states of what used to be three nullable char* slots.
# match on it is exhaustive, so an unhandled refusal is a compile error.
type Edit is Data:
  # the reply was not one <<<PATH>>>/<<<OLD>>>/<<<NEW>>>/<<<END>>> group
  Malformed{why: String}
  # well-formed, but the path failed the repository guard
  Refused{path: String}
  # all three sections present and the path passed the guard
  Block{path: String, old_str: String, new_str: String}

# after/before: the text following / preceding the first occurrence of pat,
# or "" when pat never occurs. `here` carries "s starts with pat" because a
# match cannot scrutinize the computed call — the same workaround the loop's
# verify_failed uses, and the way Base itself writes String.contains.
def after.go(s: String, +pat: String, here: Bool) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      match here:
        case True{}:
          String.drop(SCon{h, t}, String.length(pat))
        case False{}:
          after.go(t, pat, String.starts_with(t, pat))

def after(+s: String, +pat: String) -> String:
  after.go(s, pat, String.starts_with(s, pat))

def before.go(s: String, +pat: String, here: Bool) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      match here:
        case True{}:
          SNil{}
        case False{}:
          SCon{h, before.go(t, pat, String.starts_with(t, pat))}

def before(+s: String, +pat: String) -> String:
  before.go(s, pat, String.starts_with(s, pat))

# slice_range's bracket rule: the newline after the opening sentinel and the
# one before the closer belong to the delimiters, not the content.
def unbracket.lead(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      Bool.pick(String, Char.is_eq(h, '\n'), t, SCon{h, t})

def unbracket(s: String) -> String:
  String.reverse(unbracket.lead(String.reverse(unbracket.lead(s))))

def section(+text: String, +open: String, +close: String) -> String:
  unbracket(before(after(text, open), close))

def edit_path(+reply: String) -> String:
  String.trim(section(reply, "<<<PATH>>>", "<<<OLD>>>"))

def edit_old_str(+reply: String) -> String:
  section(reply, "<<<OLD>>>", "<<<NEW>>>")

# The new_str closer is the earlier of <<<PATH>>> and <<<END>>>, the same
# first_of rule bendcoder_agent.c applies when a second hunk follows.
def edit_new_str(+reply: String) -> String:
  unbracket(before(before(after(reply, "<<<NEW>>>"), "<<<PATH>>>"), "<<<END>>>"))

# One group needs all four sentinels; a second <<<PATH>>> before <<<END>>>
# is a second hunk, which this loop refuses rather than half-applies.
def edit_well_formed(+reply: String) -> Bool:
  Bool.and(
    String.contains(reply, "<<<PATH>>>"),
    Bool.and(
      String.contains(reply, "<<<OLD>>>"),
      Bool.and(
        String.contains(reply, "<<<NEW>>>"),
        Bool.and(
          String.contains(reply, "<<<END>>>"),
          Bool.not(String.contains(before(after(reply, "<<<NEW>>>"), "<<<END>>>"), "<<<PATH>>>"))))))

# The two computed checks arrive as Bools for the match, the same shape
# parse_action.of already uses.
def parse_edit.of(well_formed: Bool, path_ok: Bool, path: String, old_str: String, new_str: String) -> Edit:
  match well_formed path_ok:
    case False{} _:
      Malformed{"the reply was not a single <<<PATH>>>/<<<OLD>>>/<<<NEW>>>/<<<END>>> group"}
    case _ False{}:
      Refused{path}
    case _ _:
      Block{path, old_str, new_str}

def parse_edit(+reply: String) -> Edit:
  parse_edit.of(
    edit_well_formed(reply),
    G.in_repo(edit_path(reply)),
    edit_path(reply),
    edit_old_str(reply),
    edit_new_str(reply))

# The sentinel-delimited edit format, ported from EDIT_FORMAT_SYSTEM but
# narrowed to one group, matching what parse_edit accepts.
def edit_format_system() -> String:
  "You are Bendcoder, an autonomous coding agent improving your own repository. The repository's sources are Bend2 (.bend) and C (.c/.h) only; the goal may quote a reference implementation in another language, but the PATH and the NEW text are always in this repository's own files and languages.\nReply with EXACTLY this form and nothing else -- no prose, no code fences:\n<<<PATH>>>\nrelative/path/from/repo/root\n<<<OLD>>>\nthe exact existing text to replace, copied verbatim including indentation\n<<<NEW>>>\nthe replacement text\n<<<END>>>\nThe OLD block must appear EXACTLY ONCE in its file: include enough surrounding lines to make it unique. Leave the OLD block empty only when creating a new file. Reply with a single group only. Make one small, self-contained change."
