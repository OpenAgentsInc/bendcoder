import Base
import ./agent_primitives.bend as P
import ./action.bend as A
import ./parse.bend as E
import ./ui.bend as U
import ./selector.bend as S

# ==============================================================================
# Bender: Autonomous Coding Agent Loop
# ==============================================================================
# Classify, Generate, the question and answer types and the file tools live in
# agent_primitives.bend (`P.`); the action space in action.bend (`A.`); the
# sentinel edit parser and the Edit/ToolResult types in parse.bend (`E.`);
# colours and rendering in ui.bend (`U.`); the question set, thresholds and
# route table in selector.bend (`S.`). This file is the loop and nothing else.
# ==============================================================================

# ------------------------------------------------------------------------------
# Autonomous Agent Loop
# ------------------------------------------------------------------------------
# Bend 2.0.5 resolves names in order and has no forward references, so the loop
# cannot be a set of handlers that call back into the step function. It is one
# self-recursive `agent_step` instead: every handler returns a `Progress` and
# `agent_step` alone decides whether to go round again.

type Progress is Data:
  # The tool output to fold into the state before the next round, plus the
  # running count of consecutive search misses — the loop's own record of a
  # search_code that keeps failing, since nothing else notices it.
  Running{output: String, misses: U32}
  # Classify judged the task done; the loop stops here rather than on fuel.
  Finished{}
  # Classify chose `none`: no listed action fits the state. Halting with the
  # reason beats picking the least-bad action, which is what a Choice with no
  # escape hatch forces, since its probabilities always sum to one.
  Stalled{reason: String}

# The question set lives in selector.bend beside the thresholds and the route
# table that consume them (design rule 8); agent_step asks S.questions().

# Tool output is both shown and folded into the next round's state, so it
# arrives reusable (`+`); affine is the default and would reject the reuse.
def report_misses(+label: String, +out: String, misses: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{"\n[" ++ label ++ "]:\n" ++ out, misses})

# Anything that is not a search breaks the miss run, so a plain report resets
# the count to zero.
def report(+label: String, +out: String) -> IO(Progress):
  report_misses(label, out, 0)

# A model asked for one search string routinely prepends its reasoning, so the
# last non-empty line is taken. Mirrors extract_search_pattern in bender_agent.c.
def keep_last(best: String, line: String) -> String:
  +t = String.trim(line)
  Bool.pick(String, String.is_empty(t), best, t)

def pick_last(ls: List<&2, String>, best: String) -> String:
  List.foldl(~&2, ~String, ~String, ~keep_last, ls, best)

# A miss reads as the text tool_grep returns for one; an "error:" result (an
# empty pattern, a bad path) is a failed search all the same. A retry that
# found hits case-insensitively still says "No matches found", so that phrase
# only counts as a miss when nothing follows it.
def search_missed(+hits: String) -> Bool:
  Bool.or(
    Bool.and(String.contains(hits, "No matches found"),
             Bool.not(String.contains(hits, "case-insensitive"))),
    String.contains(hits, "error:"))

# The report labels every search with its pattern, which is what lets the
# contains-check below recognise a re-proposed one.
def search_report(+pattern: String, +hits: String, prev: U32) -> IO(Progress):
  report_misses(
    "Search for '" ++ pattern ++ "'",
    hits,
    Bool.pick(U32, search_missed(hits), U32.inc(prev), 0))

def search_with(+pattern: String, prev: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL SEARCH] Searching for '") ++ pattern ++ U.color_magenta("' ..."))
    hits : String <- P.Grep(pattern, ".")
    search_report(pattern, hits, prev)

# A pattern already run is in the state with its result, so proposing it again
# is a failed search without even grepping: skipped, but counted all the same.
def act_search_code.go(+pattern: String, prev: U32, already: Bool) -> IO(Progress):
  match already:
    case True{}:
      report_misses(
        "Search skipped",
        "'" ++ pattern ++ "' was already searched; its result is in the state above. Propose a shorter or different string, or read a file instead.",
        U32.inc(prev))
    case False{}:
      search_with(pattern, prev)

# The already-searched test is a computed value, which a match cannot inspect,
# so it is evaluated here and handed to `go` as a Bool parameter.
def act_search_code.check(state: String, +pattern: String, prev: U32) -> IO(Progress):
  act_search_code.go(pattern, prev, String.contains(state, "Search for '" ++ pattern ++ "'"))

def act_search_code(+state: String, prev: U32) -> IO(Progress):
  do IO<Progress>:
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You choose one literal search string. Reply with the string alone, nothing else.",
      "State:\n" ++ state ++ "\nGive one literal string to search this repository for. Not a regular expression. A fragment of the right name beats a full guess at it."
    )
    act_search_code.check(state, pick_last(String.lines(reply), ""), prev)

# Exec returns Done{output} or Fail{(code, output)}, so the loop can finally
# tell a passing verification from a failing one. A match scrutinizes only a
# parameter, hence the split.
def verify_failed(codeout: U32 & String) -> IO(Progress):
  (code, out) = codeout
  report("Verification FAILED (exit " ++ U32.show(code) ++ ")", out)

def verify_passed(out: String) -> IO(Progress):
  report("Verification passed", out)

def report_verify(r: Result<&1, &1, U32 & String, String>) -> IO(Progress):
  match r:
    case Fail{e}:
      verify_failed(e)
    case Done{v}:
      verify_passed(v)

def act_run_build() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EXEC] Running verification: './run_tests.sh' ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec("./run_tests.sh")
    report_verify(r)

def act_read_code() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading 'hello.bend' ..."))
    content : String <- P.Read("hello.bend", 1, 200)
    report("hello.bend (lines 1-200)", content)

def prepend_search_note(p: Progress) -> IO(Progress):
  match p:
    case Running{output, misses}:
      IO.pure(Progress, Running{
        "\n[Search kept missing]: search_code missed twice running; read_code was run instead." ++ output,
        misses})
    case other:
      IO.pure(Progress, other)

# A search that keeps missing is not converging, and nothing else in the loop
# notices on its own: the same nudge that turns an early apply_edit into a
# read in the C loop sends a repeatedly-missing search_code at read_code.
def search_stuck_read() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [SEARCH STUCK] search_code missed twice running; reading code instead."))
    p : Progress <- act_read_code()
    prepend_search_note(p)

def act_generate_answer(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ state ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen)

# ------------------------------------------------------------------------------
# apply_edit: draft an edit, apply it, verify, roll back on failure
# ------------------------------------------------------------------------------
# The Bend twin of do_apply_edit in bender_agent.c, over the existing FFI:
# ReadFile for the snapshot, EditFile to apply, Exec to verify, WriteFile to
# restore. Where the C applies a batch of hunks as a unit, this port takes one
# <<<PATH>>>/<<<OLD>>>/<<<NEW>>> group per edit and refuses a reply carrying
# more rather than silently applying a part of it. The reply is parsed by
# parse.bend into a typed Edit — Malformed, Refused or Block — so the match
# in act_apply_edit below is exhaustive and a half-applied edit is
# unrepresentable.

# Verification decides whether the edit stays. `ok` is the Bool the caller
# computes from Exec's Result — the same match-on-parameter split
# dispatch_action uses. On failure the snapshot is written back with
# WriteFile: a file the edit created is left empty rather than unlinked,
# because ReadFile cannot tell "" from "did not exist" over this FFI.
def after_verify(ok: Bool, status: U32, +path: String, +backup: String, +out: String) -> IO(Progress):
  match ok:
    case True{}:
      report("Verification passed; edit to " ++ path ++ " kept", out)
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   Verification failed (exit " ++ U32.show(status) ++ ") -- rolling the edit back."))
        rb : String <- P.WriteFile(path, backup)
        report("Verification failed; edit to " ++ path ++ " rolled back", out ++ "\n[Restore]: " ++ rb)

def verify_outcome(r: Result<&1, &1, U32 & String, String>, +path: String, +backup: String) -> IO(Progress):
  match r:
    case Done{v}:
      after_verify(True{}, 0, path, backup, v)
    case Fail{e}:
      (code, out) = e
      after_verify(False{}, code, path, backup, out)

# BENDER_VERIFY_CMD points the check at a different suite, as in the C loop;
# the command arrives + so it can be both announced and run.
def run_verify(+cmd: String, +path: String, +backup: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("   Verifying: " ++ cmd ++ " ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec(cmd)
    verify_outcome(r, path, backup)

def applied.of(r: E.ToolResult, +path: String, +backup: String) -> IO(Progress):
  match r:
    case E.Err{+message}:
      do IO<Progress>:
        rb : String <- P.WriteFile(path, backup)
        report("Edit refused by the Edit tool; snapshot restored", message ++ "\n[Restore]: " ++ rb)
    case E.Ok{+output}:
      do IO<Progress>:
        u1 : Unit <- IO.print("   " ++ output)
        env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_VERIFY_CMD")
        run_verify(Result.default(&1, &1, U32 & String, String, env, "./run_tests.sh"), path, backup)

# EditFile reports failure as "error: ..." text over the string-only FFI;
# E.tool_result reads that convention into a ToolResult, so the match above
# is over a type rather than a Bool the caller computed.
def applied(+res: String, +path: String, +backup: String) -> IO(Progress):
  applied.of(E.tool_result(res), path, backup)

# The snapshot is taken before the edit lands, so a refused apply or a
# failed verify can put the file back the way the C loop does.
def apply_block(+path: String, old_str: String, new_str: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("   Editing '" ++ path ++ "' ..."))
    backup : String <- P.ReadFile(path)
    res : String <- P.EditFile(path, old_str, new_str)
    applied(res, path, backup)

def act_apply_edit(e: E.Edit, +state: String) -> IO(Progress):
  match e:
    case E.Malformed{why}:
      report("Edit failed", why)
    case E.Refused{path}:
      report("Edit refused", "The requested path is outside the repository: " ++ path)
    case E.Block{path, old_str, new_str}:
      apply_block(path, old_str, new_str)

# do_apply_edit's Bend twin: draft the edit with the generation model, parse
# the reply into an Edit, and let act_apply_edit's match handle the rest.
# This is also the anchor path's fallback: whenever a pick comes back absent,
# unconfident or unusable, the edit drops to drafting the sentinel block.
def draft_apply_edit(+state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Drafting an edit via OpenRouter ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      E.edit_format_system(),
      "State so far:\n" ++ state)
    act_apply_edit(E.parse_edit(reply), state)

# ------------------------------------------------------------------------------
# The anchored edit: a Choice over line ids, never a transcribed old_string
# ------------------------------------------------------------------------------
# The Bend twin of try_anchor_edit in bender_agent.c. Jev picks the file, the
# line window and the anchor line; the exact `old_str` bytes are sliced out of
# the file that was read — the model is never asked to reproduce them, so it
# cannot invent them (#23's failure made impossible rather than recoverable).
# The generative model writes only the replacement text, the part that is
# genuinely new. Every pick that comes back absent, unconfident or unusable
# lands in draft_apply_edit, the sentinel path from before this change.

# Non-overlapping occurrences of pat in s. `after` hands back a strictly
# shorter suffix on each hit, and fuel — the string's own length plus one —
# bounds the walk, which is what a Bend self-call must shrink.
def occurs.go(fuel: Nat, +s: String, +pat: String, found: Bool) -> Nat:
  match fuel found:
    case 0n _:
      0n
    case _ False{}:
      0n
    case 1n+f True{}:
      +rest = E.after(s, pat)
      Nat.add(1n, occurs.go(f, rest, pat, String.contains(rest, pat)))

def occurs(+s: String, +pat: String) -> Nat:
  occurs.go(Nat.add(1n, String.length(s)), s, pat, String.contains(s, pat))

# The text of lines lo..hi (1-indexed, inclusive) joined by newlines — the
# exact bytes the file holds between those line boundaries, from the list the
# raw read produced. Not the numbered page: the "N\t" prefixes are for Jev's
# options, and the bytes applied must be the file's own.
def window_text(+ls: List<&2, String>, +lo: Nat, +hi: Nat) -> String:
  String.join(
    List.take(&2, String,
      List.drop(&2, String, ls, Nat.sub(lo, 1n)),
      Nat.add(1n, Nat.sub(hi, lo))),
    "\n")

# The window grows one line in each direction per step until its bytes occur
# exactly once in the file. tool_edit refuses a multi-match old_str anyway;
# finding the unique slice here means that refusal stays a genuine surprise.
# Radius cannot exceed the line count, so nlines+1 bounds the walk. `unique`
# arrives as a parameter — a match cannot inspect the computed occurs call —
# and each self-call computes it for the widened window.
def unique_window.go(fuel: Nat, +ls: List<&2, String>, +line: Nat, +radius: Nat, +nlines: Nat, +file: String, +text: String, unique: Bool) -> Maybe<&2, String>:
  match fuel unique:
    case 0n _:
      None{}
    case _ True{}:
      Some{text}
    case 1n+f False{}:
      +radius2 = Nat.add(radius, 1n)
      +text2 = window_text(ls, Nat.max(1n, Nat.sub(line, radius2)), Nat.min(nlines, Nat.add(line, radius2)))
      unique_window.go(f, ls, line, radius2, nlines, file, text2,
        Nat.is_eq(occurs(file, text2), 1n))

def unique_window(+ls: List<&2, String>, +line: Nat, +nlines: Nat, +file: String) -> Maybe<&2, String>:
  +text = window_text(ls, line, line)
  unique_window.go(Nat.add(1n, nlines), ls, line, 0n, nlines, file, text,
    Nat.is_eq(occurs(file, text), 1n))

# The reply is the replacement text itself; one trailing newline is a framing
# artifact of the reply rather than intended content and is dropped.
def extract_new_str(+reply: String) -> String:
  Bool.pick(String,
    String.ends_with(reply, "\n"),
    String.take(reply, Nat.sub(String.length(reply), 1n)),
    reply)

def new_format_system() -> String:
  "You are Bender, an autonomous coding agent improving your own repository.\nThe existing text to replace is given to you exactly. Reply with the replacement text and nothing else -- no prose, no code fences, no line numbers."

# The anchor's line number must land inside the file it was picked from: a
# line past the end would silently anchor the edit at the last line instead.
def anchor_line_ok(+line: U32, +nlines: Nat) -> Bool:
  Bool.and(U32.is_gt(line, 0), Bool.not(U32.is_gt(line, U32.from_nat(nlines))))

# Every bail-out lands here: the anchor could not hold, so the edit falls
# back to the sentinel draft, which still parses and applies the old way.
def anchor_fallback(+reason: String, +state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [anchor] " ++ reason ++ "; drafting the sentinel edit instead."))
    draft_apply_edit(state)

# The only generation the anchor path makes: the exact `old_str` is shown so
# the model knows what it is replacing, and it writes `new_str` — genuinely
# new text, the thing a generative model is for.
def anchor_generate(+state: String, +path: String, +line: U32, +old_str: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Writing replacement text for " ++ path ++ " around line " ++ U32.show(line) ++ " ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      new_format_system(),
      "State so far:\n" ++ state ++ "\n\nThe change anchors at line " ++ U32.show(line) ++ " of " ++ path ++ ". The exact existing text to replace is:\n" ++ old_str ++ "\nWrite the replacement text and nothing else.")
    apply_block(path, old_str, extract_new_str(reply))

def anchor_window.of(m: Maybe<&2, String>, +state: String, +path: String, +line: U32) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("no window around the anchor line is unique in the file", state)
    case Some{+old_str}:
      anchor_generate(state, path, line, old_str)

def anchor_line(ok: Bool, +line: U32, +state: String, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match ok:
    case False{}:
      anchor_fallback("the anchor named a line outside the file", state)
    case True{}:
      anchor_window.of(unique_window(String.lines(raw), U32.to_nat(line), nlines, raw), state, path, line)

def anchor_apply(r: S.AnchorRoute, +state: String, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match r:
    case S.AnchorBack{+reason}:
      anchor_fallback(reason, state)
    case S.Anchor{+line}:
      anchor_line(anchor_line_ok(line, nlines), line, state, path, raw, nlines)

# The anchor step itself: one numbered page of the file goes to Jev as
# options, the Choice picks a line id and the Noul says whether the file
# holds the thing to change at all.
def anchor_at(+state: String, +path: String, +raw: String, +nlines: Nat, +start: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' from line " ++ U32.show(start) ++ " (anchor page) ..."))
    page : String <- P.Read(path, start, U32.from_nat(S.anchor_page()))
    +raw_a : String <- P.Classify(state, S.anchor_questions(path, page))
    choice : P.Answer <- P.ParseAnswer(raw_a, "edit_anchor")
    noul : P.Answer <- P.ParseAnswer(raw_a, "edit_present")
    anchor_apply(S.anchor_route(choice, noul), state, path, raw, nlines)

def anchor_window.pick(m: Maybe<&2, U32>, +state: String, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the window Choice named no range of lines", state)
    case Some{+start}:
      anchor_at(state, path, raw, nlines, start)

# A file that fits in one page of options needs no window pick: the anchor
# Choice sees every line at once, as the cookbook's single-request search did.
def anchor_window.need(+state: String, +path: String, +raw: String, +nlines: Nat, paged: Bool) -> IO(Progress):
  match paged:
    case False{}:
      anchor_at(state, path, raw, nlines, 1)
    case True{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking a window of " ++ path ++ " ..."))
        raw_w : String <- P.Classify(state, S.edit_window_questions(path, nlines, S.anchor_page()))
        a : P.Answer <- P.ParseAnswer(raw_w, "edit_window")
        anchor_window.pick(S.edit_window_pick(a), state, path, raw, nlines)

def anchor_have_file.of(+state: String, +path: String, +raw: String, empty: Bool) -> IO(Progress):
  match empty:
    case True{}:
      anchor_fallback(path ++ " is empty or could not be read", state)
    case False{}:
      +nlines = List.length(&2, String, String.lines(raw))
      anchor_window.need(state, path, raw, nlines, Nat.is_gt(nlines, S.anchor_page()))

def anchor_have_file(+state: String, +path: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' (anchor target) ..."))
    +raw : String <- P.ReadFile(path)
    anchor_have_file.of(state, path, raw, String.is_empty(raw))

def anchor_file.pick(m: Maybe<&2, String>, +state: String) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the file Choice named no file", state)
    case Some{+path}:
      anchor_have_file(state, path)

def anchor_file(+state: String, +listing: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking the file to edit ..."))
    raw_f : String <- P.Classify(state, S.edit_file_questions(listing))
    a : P.Answer <- P.ParseAnswer(raw_f, "file_to_edit")
    anchor_file.pick(S.edit_file_pick(a), state)

def anchor_listing.of(r: Result<&1, &1, U32 & String, String>, +state: String) -> IO(Progress):
  match r:
    case Fail{e}:
      (code, out) = e
      anchor_fallback("the repository listing failed (exit " ++ U32.show(code) ++ ")", state)
    case Done{+listing}:
      anchor_file(state, listing)

# do_apply_edit's anchor twin: the repository listing is the file Choice's
# option set, the way do_read_code's picker already works.
def anchor_apply_edit(+state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Anchoring the edit with a line-id Choice ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec("git ls-files 2>/dev/null || ls -1")
    anchor_listing.of(r, state)

# The action arrives already decoded: is_none keeps "none" (a real decision —
# no listed action fits) distinct from None{} (a decision string no action
# owns, which used to fall through to generate_answer), and the match is
# exhaustive over the Action type. `misses` is the running count of failed
# searches; `search_stuck` is its comparison against the limit, computed by
# the caller because a match cannot inspect a computed value.
# The action arrives already routed: `none` and unparseable decisions are Stop
# rows in the selector's table upstream, so this match is over Action itself.
def dispatch_action(a: A.Action, state: String, misses: U32) -> IO(Progress):
  match a:
    case A.ReadCode{}:
      act_read_code()
    case A.SearchCode{}:
      act_search_code(state, misses)
    case A.RunBuild{}:
      act_run_build()
    case A.ApplyEdit{}:
      anchor_apply_edit(state)
    case A.GenerateAnswer{}:
      act_generate_answer(state)
    case A.TaskComplete{}:
      IO.pure(Progress, Finished{})

# A route that is not Act lands here: the chosen action is not run and the
# loop re-reads instead, which is the safe fallback every non-acting row
# shares. Confirm carries the same landing — the Bend loop has no one to ask
# mid-run, so an unconfirmed risky action is not run either.
def reroute(+reason: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [selector] " ++ reason ++ "; re-reading instead."))
    act_read_code()

# The selector's table decides the step: Act dispatches, the re-read rows take
# the safe fallback, and Stop stalls the loop with the reason it carried.
def run_route(r: S.Route, state: String, misses: U32) -> IO(Progress):
  match r:
    case S.Act{+action}:
      dispatch_action(action, state, misses)
    case S.Reread{+reason}:
      reroute(reason)
    case S.Skip{+reason}:
      reroute(reason)
    case S.Confirm{+action, +reason}:
      reroute(reason ++ " — a person must confirm " ++ A.show_action(action) ++ " before it runs")
    case S.Stop{+reason}:
      IO.pure(Progress, Stalled{reason})

# The short note an answer makes on the step line, for the questions that are
# not the action itself. Missing reads as what it is — the request gave no
# answer — not as a zero.
def answer_note(a: P.Answer) -> String:
  match a:
    case P.Chosen{+choice, +confidence}:
      choice ++ " (confidence " ++ F32.show(confidence) ++ ")"
    case P.Scored{+score, +confidence}:
      F32.show(score) ++ " (confidence " ++ F32.show(confidence) ++ ")"
    case P.Nouled{+probability}:
      F32.show(probability)
    case P.Missing{+reason}:
      "missing: " ++ reason

# The step's answers print as one line and route through the selector's table:
# every decision the old dispatch made inline — `none`, unparseable, missing,
# the confidence floor — is a row there now. `answers` is reusable so it can
# be both opened for the note and handed to route whole.
def run_answers(+answers: S.LoopAnswers, state: String, misses: U32) -> IO(Progress):
  match answers:
    case S.Ans{+action, +blocked, repeats, asked, risk, +progress}:
      do IO<Progress>:
        u1 : Unit <- IO.print(
          U.color_yellow("[Classify Decision] ") ++ U.color_bold(answer_note(action)) ++
          U.color_yellow(" (blocked " ++ answer_note(blocked) ++
          ", progress " ++ answer_note(progress) ++ ")"))
        u2 : Unit <- IO.print("")
        run_route(S.route(answers), state, misses)

# One round: fold the last tool output into the state, classify it, run the
# chosen action, and recurse on the remaining fuel.
# `fuel` leads the parameter list on two counts: a match reads its scrutinees in
# binder order, and a self-call must pass every argument unchanged until one
# shrinks — so the argument that shrinks has to come first.
def agent_step(fuel: Nat, phase: Progress, +step_num: U32, +state: String) -> IO(Unit):
  match fuel phase:
    # Finishing wins over exhaustion: a task completed on the last step is
    # reported as complete, not as having run out of fuel.
    case f Finished{}:
      do IO<Unit>:
        u1 : Unit <- IO.print(U.color_green("[TASK COMPLETED] Bender verified all goals are met!"))
        IO.print(U.color_cyan("================================================================================"))
    case f Stalled{reason}:
      IO.print(U.color_yellow("[STALLED] ") ++ reason)
    case 0n Running{output, _}:
      IO.print(U.color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+output, misses}:
      do IO<Unit>:
        u1 : Unit <- IO.print(U.color_cyan(U.rule()))
        u2 : Unit <- IO.print(U.color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(U.color_cyan(U.rule()))
        +c_raw : String <- P.Classify(state ++ output, S.questions())
        action : P.Answer <- P.ParseAnswer(c_raw, "action")
        blocked : P.Answer <- P.ParseAnswer(c_raw, "is_blocked")
        repeats : P.Answer <- P.ParseAnswer(c_raw, "repeats")
        asked : P.Answer <- P.ParseAnswer(c_raw, "needs_code_change")
        risk : P.Answer <- P.ParseAnswer(c_raw, "risk")
        progress : P.Answer <- P.ParseAnswer(c_raw, "progress_score")
        next : Progress <- run_answers(S.Ans{action, blocked, repeats, asked, risk, progress}, state ++ output, misses)
        agent_step(p, next, (step_num + 1 : U32), state ++ output)

# The goal is both announced and seeded into the state, so it arrives reusable.
def run_agent(fuel: Nat, +goal: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- U.render_banner()
    u2 : Unit <- IO.print(U.color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    agent_step(fuel, Running{"", 0}, 1, goal)

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bender_agent.c takes it from argv[1].
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, Result.default(&1, &1, U32 & String, String, env, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
