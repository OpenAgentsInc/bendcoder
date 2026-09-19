import Base
import ./agent_primitives.bend as P
import ./action.bend as A
import ./parse.bend as E
import ./ui.bend as U
import ./selector.bend as S
import ./reads.bend as R

# ==============================================================================
# Bendcoder: Autonomous Coding Agent Loop
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
  # loop's side-state — read cursors, the pending read a refused edit named,
  # the search-miss run and the low-confidence run — travelling as a typed
  # value rather than the C loop's globals.
  Running{rep: Report, book: R.Book}
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
    case Running{rep, +book}:
      Running{rep.act(rep, name), book}
    case other:
      p

# A reroute's reason lands in the state the way the C loop appends
# "Selector rerouted" — the next round's Classify sees why the step read
# rather than acted.
def route_note(+note: String, p: Progress) -> Progress:
  match p:
    case Running{+rep, +book}:
      Running{rep.note(rep, "\n[Selector rerouted]: " ++ note), book}
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
# person watching sees; the Report is what the loop's state learns. The Book
# arrives already updated — the handler that knows what ran knows which
# counters the step moved.
def remember(r: Report, +label: String, +out: String, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   " ++ label))
    u2 : Unit <- IO.print("   " ++ out)
    IO.pure(Progress, Running{r, book})

# Anything that is not a search breaks the miss run, so a plain report comes
# from the acted-on Book.
def report(+label: String, +out: String, +book: R.Book) -> IO(Progress):
  remember(rep.of(label, out), label, out, R.book_acted(book))

# A model asked for one search string routinely prepends its reasoning, so the
# last non-empty line is taken. Mirrors extract_search_pattern in bendcoder_agent.c.
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
# asking for it again. A miss grows the Book's consecutive-miss run; a hit
# ends it — the deterministic sibling of the `repeats` Noul.
def search_report(+pattern: String, +hits: String, +book: R.Book) -> IO(Progress):
  remember(
    rep.search("Search for '" ++ pattern ++ "'", hits, pattern ++ ":\n" ++ hits),
    "Search for '" ++ pattern ++ "'",
    hits,
    Bool.pick(R.Book, search_missed(hits), R.book_missed(book), R.book_acted(book)))

def search_with(+pattern: String, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL SEARCH] Searching for '") ++ pattern ++ U.color_magenta("' ..."))
    hits : String <- P.Grep(pattern, ".")
    search_report(pattern, hits, book)

# A pattern already run is in the state with its result, so proposing it again
# is a failed search without even grepping: skipped, but counted all the same.
def act_search_code.go(+pattern: String, +book: R.Book, already: Bool) -> IO(Progress):
  match already:
    case True{}:
      remember(
        rep.of("Search skipped",
          "'" ++ pattern ++ "' was already searched; its result is in the state above. Propose a shorter or different string, or read a file instead."),
        "Search skipped",
        "'" ++ pattern ++ "' was already searched; its result is in the state above. Propose a shorter or different string, or read a file instead.",
        R.book_missed(book))
    case False{}:
      search_with(pattern, book)

# The already-searched test is a computed value, which a match cannot inspect,
# so it is evaluated here and handed to `go` as a Bool parameter. It reads the
# same text the generative model does — the equality-on-a-typed-field version
# of this check is #14's `searched`.
def act_search_code.check(state: P.State, +pattern: String, +book: R.Book) -> IO(Progress):
  act_search_code.go(pattern, book, String.contains(P.state_text(state), "Search for '" ++ pattern ++ "'"))

def act_search_code(+state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You choose one literal search string. Reply with the string alone, nothing else.",
      "State:\n" ++ P.state_text(state) ++ "\nGive one literal string to search this repository for. Not a regular expression. A fragment of the right name beats a full guess at it."
    )
    act_search_code.check(state, pick_last(String.lines(reply), ""), book)

# Exec returns Done{output} or Fail{(code, output)}, so the loop can finally
# tell a passing verification from a failing one. A match scrutinizes only a
# parameter, hence the split.
def verify_failed(codeout: U32 & String, +book: R.Book) -> IO(Progress):
  (code, +out) = codeout
  +label = "Verification FAILED (exit " ++ U32.show(code) ++ ")"
  remember(rep.verify(label, out, P.VFail{}), label, out, R.book_acted(book))

def verify_passed(+out: String, +book: R.Book) -> IO(Progress):
  remember(rep.verify("Verification passed", out, P.VPass{}), "Verification passed", out, R.book_acted(book))

def report_verify(r: Result<&1, &1, U32 & String, String>, +book: R.Book) -> IO(Progress):
  match r:
    case Fail{e}:
      verify_failed(e, book)
    case Done{v}:
      verify_passed(v, book)

def act_run_build(+book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EXEC] Running verification: './run_tests.sh' ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec("./run_tests.sh")
    report_verify(r, book)

# ------------------------------------------------------------------------------
# read_code: the listing and README first, then a Jev file Choice with cursors
# ------------------------------------------------------------------------------
# The Bend twin of do_read_code. The first read serves the repository listing
# (already injected as index.paths) plus the README's head — the C loop reads
# them together and creates no cursor for either. Later reads ask Jev which
# tracked file to page through next: the options are the listing minus the
# files already read to the end, so the pick always names a real repository
# file and an exhausted file is never re-offered. A refused blind edit names
# its file directly, skipping the pick the way pending_read does in C.

# Lines a read serves per page — BENDCODER_READ_PAGE.
def read_page() -> U32: 200

# One page of a tracked file into the state. The cursor's `next` is the
# offset; a page that comes back as the past-end warning marks the file done
# and reports it read in full, the way serve_read_page in bendcoder_agent.c does.
def serve_read_page.fin(+label: String, +content: String, +book: R.Book, +path: String, +off: U32, past_end: Bool) -> IO(Progress):
  match past_end:
    case True{}:
      remember(
        rep.of("Read complete", path ++ " has been read in full; nothing further to read there."),
        "Read complete",
        path ++ " has been read in full; nothing further to read there.",
        R.book_served(book, path, off, True{}))
    case False{}:
      remember(rep.of(label, content), label, content,
        R.book_served(book, path, (off + read_page() : U32), False{}))

def serve_read_page(+book: R.Book, +path: String, +why: String) -> IO(Progress):
  do IO<Progress>:
    +off : U32 = R.rd_next(R.book_marks(book), path)
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' from line " ++ U32.show(off) ++ why ++ " ..."))
    +content : String <- P.Read(path, off, read_page())
    serve_read_page.fin(
      path ++ " (from line " ++ U32.show(off) ++ ")",
      content, book, path, off,
      String.starts_with(content, "<system-reminder>Warning: the file exists but is shorter"))

# The first read: the listing the state already carries plus the README's
# head, exactly the pair the C loop appends on read_phase 0.
def act_read_code.first(+state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Listing repository contents ..."))
    readme : String <- P.Read("README.md", 1, 80)
    report(
      "Repository files",
      P.state_listing(state) ++ "\n[README.md (lines 1-80)]:\n" ++ readme,
      R.book_phase0(book))

# The pick named a path; it came from the listing, so a file that no longer
# exists is a stale option, not a missing repository. serve it or say so.
def act_read_code.serve(+book: R.Book, +path: String, ok: Bool) -> IO(Progress):
  match ok:
    case True{}:
      serve_read_page(book, path, " (picked by Jev)")
    case False{}:
      report("Read failed",
        "The file Choice named " ++ path ++ ", which is not a readable repository file.",
        R.book_acted(book))

def act_read_code.found(+book: R.Book, +path: String) -> IO(Progress):
  do IO<Progress>:
    ex : String <- P.ExistsFile(path)
    act_read_code.serve(book, path, String.eq(ex, "true"))

# The pick's answer: a confident non-`none` label serves its page; everything
# else — `none`, low confidence, a missing or mistyped answer — reports the
# read that did not happen rather than guessing a file. A decline is a
# verdict on the whole option list, so the Book counts it: the route sends a
# read decision to a search once the picker has said no enough, and the
# report tells the next decision not to ask for a read again.
def act_read_code.pick(+book: R.Book, m: Maybe<&2, String>) -> IO(Progress):
  match m:
    case None{}:
      report("Read skipped",
        "The file Choice declined: no remaining repository file is judged worth reading for this goal. Do not propose read_code again — search for a term instead, or act on what is already read.",
        R.book_declined(book))
    case Some{+path}:
      act_read_code.found(book, path)

def act_read_code.jev(+state: P.State, +book: R.Book, +listing: String) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking the file to read ..."))
    raw : String <- P.Classify(state, S.read_file_questions(listing, R.rd_done(R.book_marks(book))))
    a : P.Answer <- P.ParseAnswer(raw, "file_to_read")
    act_read_code.pick(book, S.read_file_pick(a))

def act_read_code.lister(r: Result<&1, &1, U32 & String, String>, +state: P.State, +book: R.Book) -> IO(Progress):
  match r:
    case Fail{e}:
      (code, out) = e
      report("Read failed", "the repository listing failed (exit " ++ U32.show(code) ++ ")", R.book_acted(book))
    case Done{+listing}:
      act_read_code.jev(state, book, listing)

# A picker with no options is no picker — the listing travels in the state,
# but a run whose index is empty collects it the way the C loop does.
def act_read_code.ask(+state: P.State, +book: R.Book, +listing: String, empty: Bool) -> IO(Progress):
  match empty:
    case False{}:
      act_read_code.jev(state, book, listing)
    case True{}:
      do IO<Progress>:
        r : Result<&1, &1, U32 & String, String> <- P.Exec("git ls-files 2>/dev/null || ls -1")
        act_read_code.lister(r, state, book)

def act_read_code.have(+state: P.State, +book: R.Book, +listing: String) -> IO(Progress):
  act_read_code.ask(state, book, listing, String.is_empty(listing))

# read_code itself: phase 0 reads the repository, a pending refused-edit file
# serves directly, and anything else is Jev's file Choice over the listing.
def act_read_code(+state: P.State, +book: R.Book) -> IO(Progress):
  match book:
    case R.Bk{misses, reads, want, ro, low, skips}:
      match want ro:
        case _ False{}:
          act_read_code.first(state, book)
        case Some{+path} _:
          serve_read_page(book, path, " (named by the refused edit)")
        case None{} _:
          act_read_code.have(state, book, P.state_listing(state))

def act_generate_answer(+state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Calling LLM (OpenRouter) to generate code ..."))
    gen : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      "You are Bendcoder, an autonomous coding agent written in Bend2. Produce concise, direct code.",
      "State:\n" ++ P.state_text(state) ++ "\nTask: Describe the single next change that would advance this goal."
    )
    report("Generated Plan", gen, book)

# ------------------------------------------------------------------------------
# apply_edit: draft an edit, apply it, verify, roll back on failure
# ------------------------------------------------------------------------------
# The Bend twin of do_apply_edit in bendcoder_agent.c, over the existing FFI:
# ReadFile for the snapshot, EditFile to apply, Exec to verify, WriteFile to
# restore. Where the C applies a batch of hunks as a unit, this port takes one
# <<<PATH>>>/<<<OLD>>>/<<<NEW>>> group per edit and refuses a reply carrying
# more rather than silently applying a part of it. The reply is parsed by
# parse.bend into a typed Edit — Malformed, Refused or Block — so the match
# in act_apply_edit below is exhaustive and a half-applied edit is
# unrepresentable.

# A rollback puts the file back the way it was, which for a file the edit
# created is no file at all: WriteFile cannot express deletion, so the
# created case goes through sys.remove_file — snapshots_restore's unlink.
def rollback_of(existed: Bool, +path: String, +backup: String) -> IO(String):
  match existed:
    case True{}:
      P.WriteFile(path, backup)
    case False{}:
      P.RemoveFile(path)

# A green suite is only evidence about the files it reads. The coverage
# manifest run_tests.sh prints is checked for the file just edited, and a
# pass over a file no check reads is reported as the weaker thing it is —
# suite_covers in bendcoder_agent.c. See #22.
def keep_verdict(c: R.Cover, +path: String, +out: String, +book: R.Book) -> IO(Progress):
  match c:
    case R.CCovered{}:
      +label = "Verification passed; edit to " ++ path ++ " kept"
      remember(rep.edited(label, out, P.VPass{}, path), label, out, book)
    case R.CUnknown{}:
      +label = "Verification passed, but the suite reported no coverage manifest — whether it exercises " ++ path ++ " is unknown"
      remember(rep.edited(label, out, P.VPass{}, path), label, out, book)
    case R.CAbsent{}:
      +label = "Verification passed, but nothing in the suite exercises " ++ path
      remember(rep.edited(label, out, P.VPass{}, path), label, out, book)

# Verification decides whether the edit stays. `ok` is the Bool the caller
# computes from Exec's Result — the same match-on-parameter split
# dispatch_action uses. `existed` is whether the path was on disk before the
# edit: it decides which rollback the failure case takes.
def after_verify(ok: Bool, status: U32, +path: String, +backup: String, +out: String, existed: Bool, +book: R.Book) -> IO(Progress):
  match ok:
    case True{}:
      keep_verdict(R.suite_cover(out, path), path, out, book)
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   Verification failed (exit " ++ U32.show(status) ++ ") -- rolling the edit back."))
        rb : String <- rollback_of(existed, path, backup)
        +body : String = out ++ "\n[Restore]: " ++ rb
        +label : String = "Verification failed; edit to " ++ path ++ " rolled back"
        remember(rep.verify(label, body, P.VFail{}), label, body, R.book_acted(book))

def verify_outcome(r: Result<&1, &1, U32 & String, String>, +path: String, +backup: String, existed: Bool, +book: R.Book) -> IO(Progress):
  match r:
    case Done{v}:
      after_verify(True{}, 0, path, backup, v, existed, book)
    case Fail{e}:
      (code, out) = e
      after_verify(False{}, code, path, backup, out, existed, book)

# BENDCODER_VERIFY_CMD points the check at a different suite, as in the C loop;
# the command arrives + so it can be both announced and run.
def run_verify(+cmd: String, +path: String, +backup: String, existed: Bool, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("   Verifying: " ++ cmd ++ " ..."))
    r : Result<&1, &1, U32 & String, String> <- P.Exec(cmd)
    verify_outcome(r, path, backup, existed, book)

def applied.of(r: E.ToolResult, +path: String, +backup: String, existed: Bool, +book: R.Book) -> IO(Progress):
  match r:
    case E.Err{+message}:
      do IO<Progress>:
        rb : String <- rollback_of(existed, path, backup)
        report("Edit refused by the Edit tool; snapshot restored", message ++ "\n[Restore]: " ++ rb, book)
    case E.Ok{+output}:
      do IO<Progress>:
        u1 : Unit <- IO.print("   " ++ output)
        env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDCODER_VERIFY_CMD")
        run_verify(Result.default(&1, &1, U32 & String, String, env, "./run_tests.sh"), path, backup, existed, book)

# EditFile reports failure as "error: ..." text over the string-only FFI;
# E.tool_result reads that convention into a ToolResult, so the match above
# is over a type rather than a Bool the caller computed.
def applied(+res: String, +path: String, +backup: String, existed: Bool, +book: R.Book) -> IO(Progress):
  applied.of(E.tool_result(res), path, backup, existed, book)

# The snapshot is taken before the edit lands, so a refused apply or a
# failed verify can put the file back the way the C loop does — and remove it
# outright when the edit is what created it. A draft whose path does not
# exist is a creation, not a replacement: the format's empty OLD marks it,
# and it goes through WriteFile rather than an EditFile that could only
# report the file missing.
def apply_block.go(+path: String, old_str: String, new_str: String, existed: Bool, +book: R.Book) -> IO(Progress):
  match existed:
    case True{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_magenta("   Editing '" ++ path ++ "' ..."))
        backup : String <- P.ReadFile(path)
        res : String <- P.EditFile(path, old_str, new_str)
        applied(res, path, backup, existed, book)
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_magenta("   Creating '" ++ path ++ "' ..."))
        res : String <- P.WriteFile(path, new_str)
        applied(res, path, "", existed, book)

def apply_block(+path: String, old_str: String, new_str: String, existed: Bool, +book: R.Book) -> IO(Progress):
  apply_block.go(path, old_str, new_str, existed, book)

# An edit to a file the agent has not read is a guess — the same refusal
# bendcoder_agent.c applies ("has not been read yet"), and the file's name goes
# into the Book so the next read serves it rather than asking again. A path
# that does not exist yet is new code, not unread code, so the guard only
# fires on files that exist.
def apply_guarded(blind: Bool, +path: String, old_str: String, new_str: String, existed: Bool, +book: R.Book) -> IO(Progress):
  match blind:
    case True{}:
      remember(
        rep.of("Edit refused",
          path ++ " has not been read yet, so the edit was refused. Read it first, then quote its text exactly."),
        "Edit refused",
        path ++ " has not been read yet, so the edit was refused. Read it first, then quote its text exactly.",
        R.book_want(book, path))
    case False{}:
      apply_block(path, old_str, new_str, existed, book)

def act_apply_edit(e: E.Edit, +book: R.Book) -> IO(Progress):
  match e:
    case E.Malformed{why}:
      report("Edit failed", why, book)
    case E.Refused{path}:
      report("Edit refused", "The requested path is outside the repository: " ++ path, book)
    case E.Block{+path, old_str, new_str}:
      do IO<Progress>:
        ex : String <- P.ExistsFile(path)
        +exists : Bool = String.eq(ex, "true")
        apply_guarded(
          Bool.and(exists, Bool.not(R.rd_has(R.book_marks(book), path))),
          path, old_str, new_str, exists, book)

# do_apply_edit's Bend twin: draft the edit with the generation model, parse
# the reply into an Edit, and let act_apply_edit's match handle the rest.
# This is also the anchor path's fallback: whenever a pick comes back absent,
# unconfident or unusable, the edit drops to drafting the sentinel block.
def draft_apply_edit(+state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Drafting an edit via OpenRouter ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      E.edit_format_system(),
      "State so far:\n" ++ P.state_text(state))
    act_apply_edit(E.parse_edit(reply), book)

# ------------------------------------------------------------------------------
# The anchored edit: a Choice over line ids, never a transcribed old_string
# ------------------------------------------------------------------------------
# The Bend twin of try_anchor_edit in bendcoder_agent.c. Jev picks the file, the
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
  "You are Bendcoder, an autonomous coding agent improving your own repository.\nThe existing text to replace is given to you exactly. Reply with the replacement text and nothing else -- no prose, no code fences, no line numbers."

# The anchor's line number must land inside the file it was picked from: a
# line past the end would silently anchor the edit at the last line instead.
def anchor_line_ok(+line: U32, +nlines: Nat) -> Bool:
  Bool.and(U32.is_gt(line, 0), Bool.not(U32.is_gt(line, U32.from_nat(nlines))))

# Every bail-out lands here: the anchor could not hold, so the edit falls
# back to the sentinel draft, which still parses and applies the old way.
def anchor_fallback(+reason: String, +state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_yellow("   [anchor] " ++ reason ++ "; drafting the sentinel edit instead."))
    draft_apply_edit(state, book)

# The only generation the anchor path makes: the exact `old_str` is shown so
# the model knows what it is replacing, and it writes `new_str` — genuinely
# new text, the thing a generative model is for. The anchor's target was read
# in full to get here, so the edit lands on an existing file.
def anchor_generate(+state: P.State, +path: String, +line: U32, +old_str: String, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL GENERATE] Writing replacement text for " ++ path ++ " around line " ++ U32.show(line) ++ " ..."))
    reply : String <- P.GenerateText(
      "openai/gpt-oss-120b:nitro",
      new_format_system(),
      "State so far:\n" ++ P.state_text(state) ++ "\n\nThe change anchors at line " ++ U32.show(line) ++ " of " ++ path ++ ". The exact existing text to replace is:\n" ++ old_str ++ "\nWrite the replacement text and nothing else.")
    apply_block(path, old_str, extract_new_str(reply), True{}, book)

def anchor_window.of(m: Maybe<&2, String>, +state: P.State, +path: String, +line: U32, +book: R.Book) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("no window around the anchor line is unique in the file", state, book)
    case Some{+old_str}:
      anchor_generate(state, path, line, old_str, book)

def anchor_line(ok: Bool, +line: U32, +state: P.State, +path: String, +raw: String, +nlines: Nat, +book: R.Book) -> IO(Progress):
  match ok:
    case False{}:
      anchor_fallback("the anchor named a line outside the file", state, book)
    case True{}:
      anchor_window.of(unique_window(String.lines(raw), U32.to_nat(line), nlines, raw), state, path, line, book)

def anchor_apply(r: S.AnchorRoute, +state: P.State, +path: String, +raw: String, +nlines: Nat, +book: R.Book) -> IO(Progress):
  match r:
    case S.AnchorBack{+reason}:
      anchor_fallback(reason, state, book)
    case S.Anchor{+line}:
      anchor_line(anchor_line_ok(line, nlines), line, state, path, raw, nlines, book)

# The anchor step itself: one numbered page of the file goes to Jev as
# options, the Choice picks a line id and the Noul says whether the file
# holds the thing to change at all.
def anchor_at(+state: P.State, +path: String, +raw: String, +nlines: Nat, +start: U32, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' from line " ++ U32.show(start) ++ " (anchor page) ..."))
    page : String <- P.Read(path, start, U32.from_nat(S.anchor_page()))
    +raw_a : String <- P.Classify(state, S.anchor_questions(path, page))
    choice : P.Answer <- P.ParseAnswer(raw_a, "edit_anchor")
    noul : P.Answer <- P.ParseAnswer(raw_a, "edit_present")
    anchor_apply(S.anchor_route(choice, noul), state, path, raw, nlines, book)

def anchor_window.pick(m: Maybe<&2, U32>, +state: P.State, +path: String, +raw: String, +nlines: Nat, +book: R.Book) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the window Choice named no range of lines", state, book)
    case Some{+start}:
      anchor_at(state, path, raw, nlines, start, book)

# A file that fits in one page of options needs no window pick: the anchor
# Choice sees every line at once, as the cookbook's single-request search did.
def anchor_window.need(+state: P.State, +path: String, +raw: String, +nlines: Nat, paged: Bool, +book: R.Book) -> IO(Progress):
  match paged:
    case False{}:
      anchor_at(state, path, raw, nlines, 1, book)
    case True{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking a window of " ++ path ++ " ..."))
        raw_w : String <- P.Classify(state, S.edit_window_questions(path, nlines, S.anchor_page()))
        a : P.Answer <- P.ParseAnswer(raw_w, "edit_window")
        anchor_window.pick(S.edit_window_pick(a), state, path, raw, nlines, book)

# The file was just read in full, so its mark says so — the blind-edit
# guard's intent is met, and the read picker stops offering it, the way
# try_anchor_edit marks the cursor exhausted.
def anchor_have_file.of(+state: P.State, +path: String, +raw: String, +book: R.Book, empty: Bool) -> IO(Progress):
  match empty:
    case True{}:
      anchor_fallback(path ++ " is empty or could not be read", state, book)
    case False{}:
      +nlines = List.length(&2, String, String.lines(raw))
      anchor_window.need(state, path, raw, nlines, Nat.is_gt(nlines, S.anchor_page()),
        R.book_exhaust(book, path, U32.from_nat(Nat.add(1n, nlines))))

def anchor_have_file(+state: P.State, +path: String, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL READ] Reading '" ++ path ++ "' (anchor target) ..."))
    +raw : String <- P.ReadFile(path)
    anchor_have_file.of(state, path, raw, book, String.is_empty(raw))

def anchor_file.pick(m: Maybe<&2, String>, +state: P.State, +book: R.Book) -> IO(Progress):
  match m:
    case None{}:
      anchor_fallback("the file Choice named no file", state, book)
    case Some{+path}:
      anchor_have_file(state, path, book)

def anchor_file(+state: P.State, +listing: String, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL CLASSIFY] Picking the file to edit ..."))
    raw_f : String <- P.Classify(state, S.edit_file_questions(listing))
    a : P.Answer <- P.ParseAnswer(raw_f, "file_to_edit")
    anchor_file.pick(S.edit_file_pick(a), state, book)

def anchor_listing.of(r: Result<&1, &1, U32 & String, String>, +state: P.State, +book: R.Book) -> IO(Progress):
  match r:
    case Fail{e}:
      (code, out) = e
      anchor_fallback("the repository listing failed (exit " ++ U32.show(code) ++ ")", state, book)
    case Done{+listing}:
      anchor_file(state, listing, book)

# do_apply_edit's anchor twin: the repository listing is the file Choice's
# option set, the way do_read_code's picker already works. The listing already
# travels in the state's `index.paths` — injected at run_agent rather than
# asked for — so the Exec is only the fallback for a run whose index is empty.
def anchor_have_listing(+state: P.State, +listing: String, empty: Bool, +book: R.Book) -> IO(Progress):
  match empty:
    case False{}:
      anchor_file(state, listing, book)
    case True{}:
      do IO<Progress>:
        r : Result<&1, &1, U32 & String, String> <- P.Exec("git ls-files 2>/dev/null || ls -1")
        anchor_listing.of(r, state, book)

def anchor_apply_edit(+state: P.State, +book: R.Book) -> IO(Progress):
  do IO<Progress>:
    u1 : Unit <- IO.print(U.color_magenta("[TOOL EDIT] Anchoring the edit with a line-id Choice ..."))
    +listing : String = P.state_listing(state)
    anchor_have_listing(state, listing, String.is_empty(listing), book)

# The action arrives already routed: `none` and unparseable decisions are Stop
# rows in the selector's table upstream, so this match is over Action itself.
def dispatch_action(a: A.Action, +state: P.State, +book: R.Book) -> IO(Progress):
  match a:
    case A.ReadCode{}:
      act_read_code(state, book)
    case A.SearchCode{}:
      act_search_code(state, book)
    case A.RunBuild{}:
      act_run_build(book)
    case A.ApplyEdit{}:
      anchor_apply_edit(state, book)
    case A.GenerateAnswer{}:
      act_generate_answer(state, book)
    case A.TaskComplete{}:
      IO.pure(Progress, Finished{})

# A route that is not Act lands here: the chosen action is not run and the
# loop gathers information instead — a re-read when the picker is still
# live, a search once it has declined enough that another read is the same
# dead end again. Confirm carries the same landing — the Bend loop has no
# one to ask mid-run, so an unconfirmed risky action is not run either. The
# reason goes into the report, the way the C loop appends
# "Selector rerouted". `out` arrives computed because a match scrutinizes
# only parameters.
def reroute.go(+reason: String, +state: P.State, +book: R.Book, out: Bool) -> IO(Progress):
  match out:
    case True{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   [selector] " ++ reason ++ "; searching instead."))
        p : Progress <- act_search_code(state, book)
        IO.pure(Progress, acted("search_code", route_note(reason, p)))
    case False{}:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   [selector] " ++ reason ++ "; re-reading instead."))
        p : Progress <- act_read_code(state, book)
        IO.pure(Progress, acted("read_code", route_note(reason, p)))

def reroute(+reason: String, +state: P.State, +book: R.Book) -> IO(Progress):
  reroute.go(reason, state, book, R.book_read_out(book))

# Fuel policy rather than an answer route, so it stays beside the loop: on
# the penultimate or final step with no answer yet, the routed action is
# overridden by an answer — the C loop's `step >= max_steps - 1` force.
# TaskComplete and Stop keep their outcomes; everything else answers.
def run_route.forced(a: A.Action, +state: P.State, +book: R.Book) -> IO(Progress):
  match a:
    case A.TaskComplete{}:
      IO.pure(Progress, Finished{})
    case _:
      do IO<Progress>:
        u1 : Unit <- IO.print(U.color_yellow("   [selector] steps are running out and no answer has been generated; answering now."))
        p : Progress <- act_generate_answer(state, book)
        IO.pure(Progress, acted("generate_answer", p))

def run_route.act(+action: A.Action, +state: P.State, +book: R.Book, forced: Bool) -> IO(Progress):
  match forced:
    case True{}:
      run_route.forced(action, state, book)
    case False{}:
      do IO<Progress>:
        p : Progress <- dispatch_action(action, state, book)
        IO.pure(Progress, acted(A.show_action(action), p))

# The selector's table decides the step: Act dispatches, the re-read rows take
# the safe fallback, and Stop stalls the loop with the reason it carried. The
# dispatched action's name is stamped into the report here — `program.step`
# records what actually ran, which is known at dispatch, not where the
# handlers built their reports.
def run_route(r: S.Route, +state: P.State, +book: R.Book, forced: Bool) -> IO(Progress):
  match r forced:
    case S.Stop{+reason} _:
      IO.pure(Progress, Stalled{reason})
    case S.Act{+action} f:
      run_route.act(action, state, book, f)
    case S.Reread{+reason} True{}:
      run_route.forced(A.GenerateAnswer{}, state, book)
    case S.Reread{+reason} False{}:
      reroute(reason, state, book)
    case S.Skip{+reason} True{}:
      run_route.forced(A.GenerateAnswer{}, state, book)
    case S.Skip{+reason} False{}:
      reroute(reason, state, book)
    case S.Confirm{+action, reason} True{}:
      run_route.forced(action, state, book)
    case S.Confirm{+action, +reason} False{}:
      reroute(reason ++ " — a person must confirm " ++ A.show_action(action) ++ " before it runs", state, book)

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
# be both opened for the note and handed to route whole. `unread` and `stuck`
# are the loop's own facts — nothing read yet, searches missing in a row —
# which the guard rows test but Classify cannot see. `last` is the fuel
# force's window: the penultimate or final step, while no answer exists yet.
# `spent` is the under-floor run the Book already carries, so the route knows
# whether this reroute is the first or the one the floor can no longer buy.
def run_answers(+answers: S.LoopAnswers, +state: P.State, +book: R.Book, last: Bool, spent: Bool) -> IO(Progress):
  match answers:
    case S.Ans{+action, +blocked, repeats, asked, risk, +progress}:
      do IO<Progress>:
        u1 : Unit <- IO.print(
          U.color_yellow("[Classify Decision] ") ++ U.color_bold(answer_note(action)) ++
          U.color_yellow(" (blocked " ++ answer_note(blocked) ++
          ", progress " ++ answer_note(progress) ++ ")"))
        u2 : Unit <- IO.print("")
        run_route(
          S.route(answers, R.book_unread(book), R.book_stuck(book), spent, R.book_read_out(book)),
          state, book,
          Bool.and(last, Bool.not(P.state_did(state, "generate_answer"))))

# Jev saying, step after step, that it does not know. Acting on it anyway is
# how a run burns its whole budget and lands nothing — low_confidence_run's
# halt in bendcoder_agent.c, checked after this step's decision is tallied into
# the Book that run_answers and the recursion see. Returns a Progress so the
# recursion below stays the only caller of itself.
def step_decide(flailing: Bool, +answers: S.LoopAnswers, +state: P.State, +book: R.Book, last: Bool, spent: Bool) -> IO(Progress):
  match flailing:
    case True{}:
      IO.pure(Progress, Stalled{
        U32.show(R.low_limit()) ++ " consecutive decisions under the confidence floor; stopping rather than flailing."})
    case False{}:
      run_answers(answers, state, book, last, spent)

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
        u1 : Unit <- IO.print(U.color_green("[TASK COMPLETED] Bendcoder verified all goals are met!"))
        IO.print(U.color_cyan("================================================================================"))
    case f Stalled{reason}:
      IO.print(U.color_yellow("[STALLED] ") ++ reason)
    case 0n Running{_, _}:
      IO.print(U.color_yellow("[HALT] Max step fuel reached. Pausing agent loop."))
    case 1n+p Running{+rep, +book}:
      do IO<Unit>:
        u1 : Unit <- IO.print(U.color_cyan(U.rule()))
        u2 : Unit <- IO.print(U.color_bold("[STEP " ++ U32.show(step_num) ++ "] Evaluating State with Classify (TypeSafe System One)..."))
        u3 : Unit <- IO.print(U.color_cyan(U.rule()))
        +rest : Nat = p
        +state2 : P.State = apply_report(state, rep, U32.from_nat(Nat.add(1n, rest)))
        +c_raw : String <- P.Classify(state2, S.questions())
        +action : P.Answer <- P.ParseAnswer(c_raw, "action")
        blocked : P.Answer <- P.ParseAnswer(c_raw, "is_blocked")
        repeats : P.Answer <- P.ParseAnswer(c_raw, "repeats")
        asked : P.Answer <- P.ParseAnswer(c_raw, "needs_code_change")
        risk : P.Answer <- P.ParseAnswer(c_raw, "risk")
        progress : P.Answer <- P.ParseAnswer(c_raw, "progress_score")
        # `under` is the consequence-weighted floor the route tests — an
        # apply_edit in the band counts as the reroute it produces. `spent`
        # reads the run before this step's tally: the floor bought its reads,
        # so an under-floor decision that can act does — and an acted decision
        # is not a reroute, so it does not bump the run either.
        +under : Bool = S.answer_under(action)
        +spent : Bool = R.book_spent(book)
        +will_act : Bool = Bool.and(under, Bool.and(spent, S.floor_acts_answer(action)))
        +rerouted : Bool = Bool.and(under, Bool.not(will_act))
        next : Progress <- step_decide(
          R.book_flailing(book, rerouted),
          S.Ans{action, blocked, repeats, asked, risk, progress},
          state2, R.book_tally(book, rerouted), Nat.is_le(rest, 1n), spent)
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
    agent_step(fuel, Running{rep.empty(), R.book.new()}, 1, P.state.new(goal, paths, U32.from_nat(fuel)))

# BENDCODER_MAX_STEPS raises the ceiling for a longer run — a non-positive or
# unparseable value leaves the default, atoi's "0 means no override" reading.
def fuel_pos(+n: Nat, pos: Bool) -> Nat:
  match pos:
    case True{}:
      n
    case False{}:
      6n

def fuel_parsed(m: Maybe<&2, Nat>) -> Nat:
  match m:
    case Some{+n}:
      fuel_pos(n, Nat.is_gt(n, 0n))
    case None{}:
      6n

def fuel_of(r: Result<&1, &1, U32 & String, String>) -> Nat:
  match r:
    case Done{+s}:
      fuel_parsed(Nat.read(String.trim(s)))
    case Fail{e}:
      6n

# Bend has no argv — Base offers only IO.get_env — so the goal arrives as an
# environment variable, where bendcoder_agent.c takes it from argv[1].
def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDCODER_GOAL")
    steps : Result<&1, &1, U32 & String, String> <- IO.get_env("BENDCODER_MAX_STEPS")
    run_agent(
      fuel_of(steps),
      Result.default(&1, &1, U32 & String, String, env, "Project: Bendcoder repo. Goal: Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating."))
