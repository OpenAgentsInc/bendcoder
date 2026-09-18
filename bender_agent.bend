import Base
import ./agent_primitives.bend as P
import ./action.bend as A
# guard.bend holds in_repo, the path check apply_edit makes; the laws about it
# are proved in PROOF.bend, which the suite runs separately -- a module with
# unfilled laws cannot be imported by a program.
import ./guard.bend as G
import ./selector.bend as S

# ==============================================================================
# Bender: Autonomous Coding Agent Loop & Terminal UI
# ==============================================================================
# Classify, Generate, the question and answer types and the file tools all
# live in agent_primitives.bend and are reached here through `P.`; this file
# is only the loop and the terminal UI built on top of them.
# ==============================================================================

# ------------------------------------------------------------------------------
# Terminal UI Formatting Helpers
# ------------------------------------------------------------------------------
def esc() -> String:
  Char.show(Chr{27})

def color_cyan(s: String) -> String:
  esc() ++ "[36m" ++ s ++ esc() ++ "[0m"

def color_green(s: String) -> String:
  esc() ++ "[32m" ++ s ++ esc() ++ "[0m"

def color_yellow(s: String) -> String:
  esc() ++ "[33m" ++ s ++ esc() ++ "[0m"

def color_magenta(s: String) -> String:
  esc() ++ "[35m" ++ s ++ esc() ++ "[0m"

def color_bold(s: String) -> String:
  esc() ++ "[1m" ++ s ++ esc() ++ "[0m"

def rule() -> String:
  "--------------------------------------------------------------------------------"

def render_banner() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- IO.print(color_cyan("================================================================================"))
    u2 : Unit <- IO.print(color_bold("  [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)"))
    IO.print(color_cyan("================================================================================"))


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
    u1 : Unit <- IO.print(color_yellow("   " ++ label))
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
    u1 : Unit <- IO.print(color_magenta("[TOOL SEARCH] Searching for '") ++ pattern ++ color_magenta("' ..."))
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
    u1 : Unit <- IO.print(color_magenta("[TOOL EXEC] Running verification: './run_tests.sh' ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec("./run_tests.sh")
    report_verify(r)

def act_read_code() -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL READ] Reading 'hello.bend' ..."))
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
    u1 : Unit <- IO.print(color_yellow("   [SEARCH STUCK] search_code missed twice running; reading code instead."))
    p : Progress <- act_read_code()
    prepend_search_note(p)

def act_generate_answer(state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
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
# more rather than silently applying a part of it.

# A drafted edit as parsed from the model's reply: the three meaningful
# states of what used to be three nullable char* slots. match on it is
# exhaustive, so an unhandled refusal is a compile error. (Moves to
# bender_parse.bend when #15 lands it with the parser.)
type Edit is Data:
  # the reply was not one <<<PATH>>>/<<<OLD>>>/<<<NEW>>>/<<<END>>> group
  Malformed{why: String}
  # well-formed, but the path failed the repository guard
  Refused{path: String}
  # all three sections present and the path passed the guard
  Block{path: String, old_str: String, new_str: String}

# after/before: the text following / preceding the first occurrence of pat,
# or "" when pat never occurs. `here` carries "s starts with pat" because a
# match cannot scrutinize the computed call — the same workaround
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
# first_of rule bender_agent.c applies when a second hunk follows.
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
  "You are Bender, an autonomous coding agent improving your own repository.\nReply with EXACTLY this form and nothing else -- no prose, no code fences:\n<<<PATH>>>\nrelative/path/from/repo/root\n<<<OLD>>>\nthe exact existing text to replace, copied verbatim including indentation\n<<<NEW>>>\nthe replacement text\n<<<END>>>\nThe OLD block must appear EXACTLY ONCE in its file: include enough surrounding lines to make it unique. Leave the OLD block empty only when creating a new file. Reply with a single group only. Make one small, self-contained change."

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
        u1 : Unit <- IO.print(color_yellow("   Verification failed (exit " ++ U32.show(status) ++ ") -- rolling the edit back."))
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
    u1 : Unit <- IO.print(color_magenta("   Verifying: " ++ cmd ++ " ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec(cmd)
    verify_outcome(r, path, backup)

def applied.of(failed: Bool, +res: String, +path: String, +backup: String) -> IO(Progress):
  match failed:
    case True{}:
      do IO<Progress>:
        rb : String <- P.WriteFile(path, backup)
        report("Edit refused by the Edit tool; snapshot restored", res ++ "\n[Restore]: " ++ rb)
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print("   " ++ res)
        env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_VERIFY_CMD")
        run_verify(Result.default(&1, &1, U32 & String, String, env, "./run_tests.sh"), path, backup)

# EditFile reports failure as "error: ..." text; the check is computed here
# and matched in applied.of, because the match needs it as a parameter.
def applied(+res: String, +path: String, +backup: String) -> IO(Progress):
  applied.of(String.starts_with(res, "error:"), res, path, backup)

# The snapshot is taken before the edit lands, so a refused apply or a
# failed verify can put the file back the way the C loop does.
def apply_block(+path: String, old_str: String, new_str: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("   Editing '" ++ path ++ "' ..."))
    backup : String <- P.ReadFile(path)
    res : String <- P.EditFile(path, old_str, new_str)
    applied(res, path, backup)

def act_apply_edit(e: Edit, +state: String) -> IO(Progress):
  match e:
    case Malformed{why}:
      report("Edit failed", why)
    case Refused{path}:
      report("Edit refused", "The requested path is outside the repository: " ++ path)
    case Block{path, old_str, new_str}:
      apply_block(path, old_str, new_str)

# do_apply_edit's Bend twin: draft the edit with the generation model, parse
# the reply into an Edit, and let act_apply_edit's match handle the rest.
def draft_apply_edit(+state: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(color_magenta("[TOOL EDIT] Drafting an edit via OpenRouter ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      edit_format_system(),
      "State so far:\n" ++ state)
    act_apply_edit(parse_edit(reply), state)

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
      draft_apply_edit(state)
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
    u1 : Unit <- IO.print(color_yellow("   [selector] " ++ reason ++ "; re-reading instead."))
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
          color_yellow("[Classify Decision] ") ++ color_bold(answer_note(action)) ++
          color_yellow(" (blocked " ++ answer_note(blocked) ++
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
        u1 : Unit <- IO.print(color_green("[TASK COMPLETED] Bender verified all goals are met!"))
        IO.print(color_cyan("================================================================================"))
    case f Stalled{reason}:
      IO.print(color_yellow("[STALLED] ") ++ reason)
    case 0n Running{output, _}:
      IO.print(color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+output, misses}:
      do IO<Unit>:
        u1 : Unit <- IO.print(color_cyan(rule()))
        u2 : Unit <- IO.print(color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(color_cyan(rule()))
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
    u1 : Unit <- render_banner()
    u2 : Unit <- IO.print(color_bold("[GOAL] Initial Goal: ") ++ goal)
    u3 : Unit <- IO.print("")
    agent_step(fuel, Running{"", 0}, 1, goal)

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bender_agent.c takes it from argv[1].
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDER_GOAL")
    run_agent(6n, Result.default(&1, &1, U32 & String, String, env, "Project: Bender repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
