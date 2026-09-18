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

# What one step hands back to the state: the observation it recorded plus the
# structured fields it moved — which action ran, what verification returned,
# which paths it left changed, what a search retrieved. Each Maybe is None{}
# when the step did not touch that field, so a read does not pretend to have
# verified, and an unverified edit does not count as a changed path.
type Report is Data:
  Rep{
    obs: Maybe<&2, String>,      # an entry for `observations`
    act: Maybe<&2, String>,      # the action that ran, for `program`
    verify: Maybe<&2, P.Verif>,  # the outcome for `facts.verification`
    changed: List<&2, String>,   # paths for `facts.changed_paths`
    hits: List<&2, String>       # entries for `index.search_hits`
  }

type Progress is Data:
  # The step's report to fold into the state before the next round, plus the
  # running count of consecutive search misses — the loop's own record of a
  # search_code that keeps failing, since nothing else notices it.
  Running{rep: Report, misses: U32}
  # Classify judged the task done; the loop stops here rather than on fuel.
  Finished{}
  # Classify chose `none`: no listed action fits the state. Halting with the
  # reason beats picking the least-bad action, which is what a Choice with no
  # escape hatch forces, since its probabilities always sum to one.
  Stalled{reason: String}

# The question set lives in selector.bend beside the thresholds and the route
# table that consume them (design rule 8); agent_step asks S.questions().

# ------------------------------------------------------------------------------
# Reports: what the handlers build, and how one folds into the state
# ------------------------------------------------------------------------------
# The report shapes the handlers produce. `obs` carries the same
# "[label]:\nbody" entry the string state appended — the List<Step> of #14
# renders into this slot when it lands.
def rep.of(+label: String, +body: String) -> Report:
  Rep{Some{"\n[" ++ label ++ "]:\n" ++ body}, None{}, None{}, Nil{}, Nil{}}

# A search records its result under `index.search_hits` as well as in the
# observations: the index is the retrieval a later question reads without
# the model having to ask for it again.
def rep.search(+label: String, +body: String, +hit: String) -> Report:
  Rep{Some{"\n[" ++ label ++ "]:\n" ++ body}, None{}, None{}, Nil{}, [hit]}

def rep.verify(+label: String, +body: String, v: P.Verif) -> Report:
  Rep{Some{"\n[" ++ label ++ "]:\n" ++ body}, None{}, Some{v}, Nil{}, Nil{}}

def rep.edited(+label: String, +body: String, v: P.Verif, +path: String) -> Report:
  Rep{Some{"\n[" ++ label ++ "]:\n" ++ body}, None{}, Some{v}, [path], Nil{}}

def rep.empty() -> Report:
  Rep{None{}, None{}, None{}, Nil{}, Nil{}}

# rep.note prepends a line to the observation (the search-stuck nudge);
# rep.act stamps the action that ran, which is known at dispatch, not where
# the report was built.
def rep.obs.pre(+obs: Maybe<&2, String>, +note: String) -> Maybe<&2, String>:
  match obs:
    case Some{+o}:
      Some{note ++ o}
    case None{}:
      Some{note}

def rep.note(+r: Report, +note: String) -> Report:
  match r:
    case Rep{+obs, +act, +verify, +changed, +hits}:
      Rep{rep.obs.pre(obs, note), act, verify, changed, hits}

def rep.act(+r: Report, +name: String) -> Report:
  match r:
    case Rep{+obs, act, +verify, +changed, +hits}:
      Rep{obs, Some{name}, verify, changed, hits}

def acted(+name: String, p: Progress) -> Progress:
  match p:
    case Running{rep, misses}:
      Running{rep.act(rep, name), misses}
    case other:
      p

# The pieces of the record a report moves. A Maybe that is None{} leaves the
# field it guards alone: a step that ran no verification does not touch
# facts.verification.
def push_maybe(+xs: List<&2, String>, m: Maybe<&2, String>) -> List<&2, String>:
  match m:
    case Some{+v}:
      List.append(&2, String, xs, [v])
    case None{}:
      xs

# `program.step` is the action just run; a new one pushes the outgoing step
# into steps_done — the selector design's shape keeps the two distinct. The
# pair of Bools arrives computed, the way every match-on-computed in this
# codebase is split.
def done_push(+done: List<&2, String>, +prev: String, m: Maybe<&2, String>, prev_has: Bool) -> List<&2, String>:
  match m prev_has:
    case Some{+a} True{}:
      List.append(&2, String, done, [prev])
    case _ _:
      done

def step_or(+cur: String, m: Maybe<&2, String>) -> String:
  match m:
    case Some{+v}:
      v
    case None{}:
      cur

def verif_or(+cur: P.Verif, m: Maybe<&2, P.Verif>) -> P.Verif:
  match m:
    case Some{v}:
      v
    case None{}:
      cur

# The state transition itself: one report folded in, newest entries last.
def apply_report(s: P.State, r: Report, +left: U32) -> P.State:
  match s r:
    case P.St{directive, +step, done, obs, changed, verif, paths, hits, _}
         Rep{nobs, +nact, nver, nchanged, nhits}:
      P.St{
        directive,
        step_or(step, nact),
        done_push(done, step, nact, Bool.not(String.is_empty(step))),
        push_maybe(obs, nobs),
        List.append(&2, String, changed, nchanged),
        verif_or(verif, nver),
        paths,
        List.append(&2, String, hits, nhits),
        left}

# One tool result, both shown and remembered: the label/body pair is what the
# person watching sees; the Report is what the loop's state learns.
def remember(r: Report, +label: String, +out: String, misses: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{r, misses})

def report_misses(+label: String, +out: String, misses: U32) -> IO(Progress):
  remember(rep.of(label, out), label, out, misses)

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
# contains-check below recognise a re-proposed one. The hits also land under
# index.search_hits — the retrieval a later question reads without the model
# asking for it again.
def search_report(+pattern: String, +hits: String, prev: U32) -> IO(Progress):
  remember(
    rep.search("Search for '" ++ pattern ++ "'", hits, pattern ++ ":\n" ++ hits),
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
# so it is evaluated here and handed to `go` as a Bool parameter. It reads the
# same text the generative model does — the equality-on-a-typed-field version
# of this check is #14's `searched`.
def act_search_code.check(state: P.State, +pattern: String, prev: U32) -> IO(Progress):
  act_search_code.go(pattern, prev, String.contains(P.state_text(state), "Search for '" ++ pattern ++ "'"))

def act_search_code(+state: P.State, prev: U32) -> IO(Progress):
  do IO<Progress>:
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You choose one literal search string. Reply with the string alone, nothing else.",
      "State:\n" ++ P.state_text(state) ++ "\nGive one literal string to search this repository for. Not a regular expression. A fragment of the right name beats a full guess at it."
    )
    act_search_code.check(state, pick_last(String.lines(reply), ""), prev)

# Exec returns Done{output} or Fail{(code, output)}, so the loop can finally
# tell a passing verification from a failing one. A match scrutinizes only a
# parameter, hence the split.
def verify_failed(codeout: U32 & String) -> IO(Progress):
  (code, +out) = codeout
  +label = "Verification FAILED (exit " ++ U32.show(code) ++ ")"
  remember(rep.verify(label, out, P.VFail{}), label, out, 0)

def verify_passed(+out: String) -> IO(Progress):
  remember(rep.verify("Verification passed", out, P.VPass{}), "Verification passed", out, 0)

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

def prepend_search_note(p: Progress) -> Progress:
  match p:
    case Running{rep, misses}:
      Running{
        rep.note(rep, "\n[Search kept missing]: search_code missed twice running; read_code was run instead."),
        misses}
    case other:
      p

# A search that keeps missing is not converging, and nothing else in the loop
# notices on its own: the same nudge that turns an early apply_edit into a
# read in the C loop sends a repeatedly-missing search_code at read_code.
def search_stuck_read() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [SEARCH STUCK] search_code missed twice running; reading code instead."))
    p : Progress <- act_read_code()
    IO.pure(Progress, acted("read_code", prepend_search_note(p)))

def act_generate_answer(state: P.State) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bender, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ P.state_text(state) ++ "\nTask: Describe the single next change that would advance this goal."
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
      +label = "Verification passed; edit to " ++ path ++ " kept"
      remember(rep.edited(label, out, P.VPass{}, path), label, out, 0)
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   Verification failed (exit " ++ U32.show(status) ++ ") -- rolling the edit back."))
        rb : String <- P.WriteFile(path, backup)
        +body : String = out ++ "\n[Restore]: " ++ rb
        +label : String = "Verification failed; edit to " ++ path ++ " rolled back"
        remember(rep.verify(label, body, P.VFail{}), label, body, 0)

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

def act_apply_edit(e: E.Edit, +state: P.State) -> IO(Progress):
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
def draft_apply_edit(+state: P.State) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Drafting an edit via OpenRouter ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      E.edit_format_system(),
      "State so far:\n" ++ P.state_text(state))
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
def anchor_fallback(+reason: String, +state: P.State) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [anchor] " ++ reason ++ "; drafting the sentinel edit instead."))
    draft_apply_edit(state)

# The only generation the anchor path makes: the exact `old_str` is shown so
# the model knows what it is replacing, and it writes `new_str` — genuinely
# new text, the thing a generative model is for.
def anchor_generate(+state: P.State, +path: String, +line: U32, +old_str: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Writing replacement text for " ++ path ++ " around line " ++ U32.show(line) ++ " ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      new_format_system(),
      "State so far:\n" ++ P.state_text(state) ++ "\n\nThe change anchors at line " ++ U32.show(line) ++ " of " ++ path ++ ". The exact existing text to replace is:\n" ++ old_str ++ "\nWrite the replacement text and nothing else.")
    apply_block(path, old_str, extract_new_str(reply))

def anchor_window.of(m: Maybe<&2, String>, +state: P.State, +path: String, +line: U32) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("no window around the anchor line is unique in the file", state)
    case Some{+old_str}:
      anchor_generate(state, path, line, old_str)

def anchor_line(ok: Bool, +line: U32, +state: P.State, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match ok:
    case False{}:
      anchor_fallback("the anchor named a line outside the file", state)
    case True{}:
      anchor_window.of(unique_window(String.lines(raw), U32.to_nat(line), nlines, raw), state, path, line)

def anchor_apply(r: S.AnchorRoute, +state: P.State, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match r:
    case S.AnchorBack{+reason}:
      anchor_fallback(reason, state)
    case S.Anchor{+line}:
      anchor_line(anchor_line_ok(line, nlines), line, state, path, raw, nlines)

# The anchor step itself: one numbered page of the file goes to Jev as
# options, the Choice picks a line id and the Noul says whether the file
# holds the thing to change at all.
def anchor_at(+state: P.State, +path: String, +raw: String, +nlines: Nat, +start: U32) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' from line " ++ U32.show(start) ++ " (anchor page) ..."))
    page : String <- P.Read(path, start, U32.from_nat(S.anchor_page()))
    +raw_a : String <- P.Classify(state, S.anchor_questions(path, page))
    choice : P.Answer <- P.ParseAnswer(raw_a, "edit_anchor")
    noul : P.Answer <- P.ParseAnswer(raw_a, "edit_present")
    anchor_apply(S.anchor_route(choice, noul), state, path, raw, nlines)

def anchor_window.pick(m: Maybe<&2, U32>, +state: P.State, +path: String, +raw: String, +nlines: Nat) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the window Choice named no range of lines", state)
    case Some{+start}:
      anchor_at(state, path, raw, nlines, start)

# A file that fits in one page of options needs no window pick: the anchor
# Choice sees every line at once, as the cookbook's single-request search did.
def anchor_window.need(+state: P.State, +path: String, +raw: String, +nlines: Nat, paged: Bool) -> IO(Progress):
  match paged:
    case False{}:
      anchor_at(state, path, raw, nlines, 1)
    case True{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking a window of " ++ path ++ " ..."))
        raw_w : String <- P.Classify(state, S.edit_window_questions(path, nlines, S.anchor_page()))
        a : P.Answer <- P.ParseAnswer(raw_w, "edit_window")
        anchor_window.pick(S.edit_window_pick(a), state, path, raw, nlines)

def anchor_have_file.of(+state: P.State, +path: String, +raw: String, empty: Bool) -> IO(Progress):
  match empty:
    case True{}:
      anchor_fallback(path ++ " is empty or could not be read", state)
    case False{}:
      +nlines = List.length(&2, String, String.lines(raw))
      anchor_window.need(state, path, raw, nlines, Nat.is_gt(nlines, S.anchor_page()))

def anchor_have_file(+state: P.State, +path: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' (anchor target) ..."))
    +raw : String <- P.ReadFile(path)
    anchor_have_file.of(state, path, raw, String.is_empty(raw))

def anchor_file.pick(m: Maybe<&2, String>, +state: P.State) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the file Choice named no file", state)
    case Some{+path}:
      anchor_have_file(state, path)

def anchor_file(+state: P.State, +listing: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking the file to edit ..."))
    raw_f : String <- P.Classify(state, S.edit_file_questions(listing))
    a : P.Answer <- P.ParseAnswer(raw_f, "file_to_edit")
    anchor_file.pick(S.edit_file_pick(a), state)

def anchor_listing.of(r: Result<&1, &1, U32 & String, String>, +state: P.State) -> IO(Progress):
  match r:
    case Fail{e}:
      (code, out) = e
      anchor_fallback("the repository listing failed (exit " ++ U32.show(code) ++ ")", state)
    case Done{+listing}:
      anchor_file(state, listing)

# do_apply_edit's anchor twin: the repository listing is the file Choice's
# option set, the way do_read_code's picker already works. The listing already
# travels in the state's `index.paths` — injected at run_agent rather than
# asked for — so the Exec is only the fallback for a run whose index is empty.
def anchor_have_listing(+state: P.State, +listing: String, empty: Bool) -> IO(Progress):
  match empty:
    case False{}:
      anchor_file(state, listing)
    case True{}:
      do IO<Progress>:
        r : Result<&1, &1, U32 & String, String> <- P.Exec("git ls-files 2>/dev/null || ls -1")
        anchor_listing.of(r, state)

def anchor_apply_edit(+state: P.State) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Anchoring the edit with a line-id Choice ..."))
    +listing : String = P.state_listing(state)
    anchor_have_listing(state, listing, String.is_empty(listing))

# The action arrives already decoded: is_none keeps "none" (a real decision —
# no listed action fits) distinct from None{} (a decision string no action
# owns, which used to fall through to generate_answer), and the match is
# exhaustive over the Action type. `misses` is the running count of failed
# searches; `search_stuck` is its comparison against the limit, computed by
# the caller because a match cannot inspect a computed value.
# The action arrives already routed: `none` and unparseable decisions are Stop
# rows in the selector's table upstream, so this match is over Action itself.
def dispatch_action(a: A.Action, state: P.State, misses: U32) -> IO(Progress):
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
    p : Progress <- act_read_code()
    IO.pure(Progress, acted("read_code", p))

# The selector's table decides the step: Act dispatches, the re-read rows take
# the safe fallback, and Stop stalls the loop with the reason it carried. The
# dispatched action's name is stamped into the report here — `program.step`
# records what actually ran, which is known at dispatch, not where the
# handlers built their reports.
def run_route(r: S.Route, state: P.State, misses: U32) -> IO(Progress):
  match r:
    case S.Act{+action}:
      do IO<Progress>:
        p : Progress <- dispatch_action(action, state, misses)
        IO.pure(Progress, acted(A.show_action(action), p))
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
def run_answers(+answers: S.LoopAnswers, state: P.State, misses: U32) -> IO(Progress):
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
def agent_step(fuel: Nat, phase: Progress, +step_num: U32, +state: P.State) -> IO(Unit):
  match fuel phase:
    # Finishing wins over exhaustion: a task completed on the last step is
    # reported as complete, not as having run out of fuel.
    case f Finished{}:
      do IO<Unit>:
        u1 : Unit <- IO.print(U.color_green("[TASK COMPLETED] Bender verified all goals are met!"))
        IO.print(U.color_cyan("================================================================================"))
    case f Stalled{reason}:
      IO.print(U.color_yellow("[STALLED] ") ++ reason)
    case 0n Running{_, _}:
      IO.print(U.color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+rep, misses}:
      do IO<Unit>:
        u1 : Unit <- IO.print(U.color_cyan(U.rule()))
        u2 : Unit <- IO.print(U.color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(U.color_cyan(U.rule()))
        +rest : Nat = p
        +state2 : P.State = apply_report(state, rep, U32.from_nat(Nat.add(1n, rest)))
        +c_raw : String <- P.Classify(state2, S.questions())
        action : P.Answer <- P.ParseAnswer(c_raw, "action")
        blocked : P.Answer <- P.ParseAnswer(c_raw, "is_blocked")
        repeats : P.Answer <- P.ParseAnswer(c_raw, "repeats")
        asked : P.Answer <- P.ParseAnswer(c_raw, "needs_code_change")
        risk : P.Answer <- P.ParseAnswer(c_raw, "risk")
        progress : P.Answer <- P.ParseAnswer(c_raw, "progress_score")
        next : Progress <- run_answers(S.Ans{action, blocked, repeats, asked, risk, progress}, state2, misses)
        agent_step(rest, next, (step_num + 1 : U32), state2)

# The repository listing is filtered to non-empty lines — a trailing newline
# leaves a last "" that is not a path.
def non_empty_line(line: String) -> Bool:
  Bool.not(String.is_empty(String.trim(line)))

# The injected index: the listing runs once at run_agent, not once per tool
# that wants it — retrieval the model must ask for is not called, so it
# travels in `index.paths` from the first Classify on. A failed listing leaves
# the index empty, and the anchor's file Choice falls back to running the
# Exec itself, the way it always did.
def paths_of(r: Result<&1, &1, U32 & String, String>) -> List<&2, String>:
  match r:
    case Done{+listing}:
      List.filter(~String, ~non_empty_line, String.lines(listing))
    case Fail{e}:
      {Nil{} : List<&2, String>}

# The goal is both announced and seeded into the state as `directive`, so it
# arrives reusable.
def run_agent(+fuel: Nat, +goal: String) -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- U.render_banner()
    u2 : Unit <- IO.print(U.color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    r : Result<&1, &1, U32 & String, String> <- P.Exec("git ls-files 2>/dev/null || ls -1")
    +paths : List<&2, String> = paths_of(r)
    u4 : Unit <- IO.print(
      U.color_magenta("[INDEX] ") ++
      Nat.show(List.length(&2, String, paths)) ++
      " repository paths injected into the state.")
    agent_step(fuel, Running{rep.empty(), 0}, 1, P.state.new(goal, paths, U32.from_nat(fuel)))

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bender_agent.c takes it from argv[1].
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, Result.default(&1, &1, U32 & String, String, env, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
