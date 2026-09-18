import Base
import ./agent_primitives.bend as P
import ./action.bend as A

# ==============================================================================
# Bender Selector: the question set, the thresholds, and the answers-to-action
# table, in one reviewable module (design rules 7 and 8)
# ==============================================================================
# Rule 8: the questions Bender asks and the thresholds that consume them must
# review together — a threshold means nothing without the question it reads,
# and a question nobody routes is dead weight. Both live here.
#
# Rule 7: route on probability and confidence with thresholds tuned on labeled
# data, and record what was measured. Each threshold below says what it was
# tuned on; the ones not yet measured say so rather than dressing a guess up
# as data.
#
# The answers-to-action mapping, as the selector design gives it:
#
#   Answers                                            Route
#   -------------------------------------------------  -------------------------
#   `action` missing, mistyped, or names no action     Halt with a reason
#   `action` is `none`                                 Halt with a reason
#   `action` confidence under the floor                Do not act; re-read or ask
#   `repeats` high                                     Do not take that action again
#   `risk` at the top level and the goal did not ask   Confirm before running
#   otherwise                                          Act on the choice
#
# In Bend the table is a match over typed answers, which is where
# exhaustiveness earns its keep: every branch is checked, and `LoopAnswers`
# gives each question a field that every consumer's pattern must bind — adding
# a question and forgetting to route it is a compile error, not a dead row.
# bender_agent.c carries the same table in route_decision; keep them in step.

# ------------------------------------------------------------------------------
# The question set
# ------------------------------------------------------------------------------
# One entry per field of LoopAnswers, in the same order. `apply_edit` is
# offered so the risk gate has something to gate; the Bend loop still reports
# it unimplemented when it is routed to.
def questions() -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "action",
      "Based on the current state, what is the single next best action to advance or verify the task?",
      [
        P.Opt{A.show_action(A.ReadCode{}), "Read source code or repository files to understand context or inspect implementations"},
        P.Opt{A.show_action(A.SearchCode{}), "Search the repository for a literal string to find which files are relevant"},
        P.Opt{A.show_action(A.RunBuild{}), "Run build, compile, or test command to check if code works or reproduces an error"},
        P.Opt{A.show_action(A.ApplyEdit{}), "Change the code on disk: the fix is understood and a concrete edit to a known file can be written now"},
        P.Opt{A.show_action(A.GenerateAnswer{}), "Synthesize code, write a patch, or generate a fix using the LLM"},
        P.Opt{A.show_action(A.TaskComplete{}), "The task is successfully resolved, verified, and complete"},
        P.Opt{"none", "No listed action fits: the state does not yet support a next step"}
      ]
    },
    P.NoulQ{
      "is_blocked",
      "Is the task blocked by an error or failing verification?"
    },
    P.NoulQ{
      "repeats",
      "Would the next action repeat something the state already records having tried without success?"
    },
    P.NoulQ{
      "needs_code_change",
      "Does satisfying this goal require editing files in this repository, rather than only answering in prose?"
    },
    P.ScoreQ{
      "risk",
      "How much can the chosen next action destroy or expose?",
      [
        "0: Read-only inspection; nothing on disk changes",
        "1: Runs a command or generates text; reversible",
        "2: Writes to disk or can break the build"
      ]
    },
    P.ScoreQ{
      "progress_score",
      "How close is the current state to a fully verified resolution?",
      [
        "0: Just starting / investigating",
        "1: Root cause understood, attempting fix",
        "2: Fully fixed, verified, and ready to finish"
      ]
    }
  ]

# One typed Answer per question in questions(), in the same order. The record
# is what makes "a question nobody routes" a compile error: constructor
# patterns must bind every field, so adding one is seen by every consumer.
type LoopAnswers is Data:
  Ans{action: P.Answer, blocked: P.Answer, repeats: P.Answer,
      asked: P.Answer, risk: P.Answer, progress: P.Answer}

# ------------------------------------------------------------------------------
# The thresholds
# ------------------------------------------------------------------------------

# Floor on the `action` Choice's confidence. Measured on the delegation runs:
# steps that advanced the task sat at 0.55 and above, while runs that flailed
# for ten steps and landed nothing sat between 0.21 and 0.43. 0.45 separates
# the two; under it the loop re-reads instead of acting on a guess.
def confidence_floor() -> F32: 0.45

# apply_edit's own floor, higher by consequence: a wrong read costs a page, a
# wrong edit writes to disk and can break the build. Not yet measured on
# labeled edit outcomes — the failed edit runs in #24 are exactly the data to
# collect — so until then it sits above the measured general floor.
def edit_confidence_floor() -> F32: 0.65

# `repeats` noul above which the chosen action reads as a retried failure.
# Carried over from the C loop's REPEATS_FLOOR; not yet tuned on labeled data.
def repeats_floor() -> F32: 0.60

# `risk` is a Score over three levels and the returned score is the
# probability-weighted mean over them, so "at the top level" reads as a mean
# inside the top band rather than exactly 2. Not yet tuned on labeled data.
def risk_top() -> F32: 1.5

# `needs_code_change` noul below which the goal did not ask for edits. Not yet
# tuned on labeled data.
def asked_floor() -> F32: 0.50

# ------------------------------------------------------------------------------
# The route: what the selector hands the loop
# ------------------------------------------------------------------------------
type Route is Data:
  # Run the chosen action.
  Act{action: A.Action}
  # Confidence under the floor: do not act; re-read or ask.
  Reread{reason: String}
  # `repeats` is high: the same action again is how #24 kept trying.
  Skip{reason: String}
  # Top-level risk the goal did not ask for: a person confirms before it runs.
  Confirm{action: A.Action, reason: String}
  # `none`, a decision naming no action, or no usable answer at all.
  Stop{reason: String}

# A Noul answer reads as its probability; anything else — a missing or
# mistyped answer — reads as "not high", the safe direction for a gate.
def noul_above(+a: P.Answer, +floor: F32) -> Bool:
  match a:
    case P.Nouled{+probability}:
      F32.is_gt(probability, floor)
    case _:
      False{}

# A Score is the probability-weighted mean over the rubric levels, so the top
# level dominating reads as a mean inside the top band. A missing or mistyped
# answer reads as "not at the top".
def scored_top(+a: P.Answer, +top: F32) -> Bool:
  match a:
    case P.Scored{+score, confidence}:
      F32.is_ge(score, top)
    case _:
      False{}

# The risk row's second half: the goal asked for it when needs_code_change
# reads at or above the floor. A missing or mistyped answer cannot show the
# goal asked, so it reads as not-asked — the safe direction for a gate.
def unasked(+a: P.Answer) -> Bool:
  match a:
    case P.Nouled{+probability}:
      F32.is_lt(probability, asked_floor())
    case _:
      True{}

# The consequence-weighted floor for one action: apply_edit writes to disk and
# can break the build, so it clears a higher bar than read-only actions.
def under_floor(a: A.Action, +confidence: F32) -> Bool:
  match a:
    case A.ApplyEdit{}:
      F32.is_lt(confidence, edit_confidence_floor())
    case _:
      F32.is_lt(confidence, confidence_floor())

# The table's gated rows. A match scrutinizes only parameters, so the
# comparisons arrive as Bool scrutinees computed by the caller — which is also
# what lets the laws below pin each row, since the F32 comparisons are opaque
# to the checker.
def route.gate(under: Bool, rep: Bool, risky: Bool, a: A.Action) -> Route:
  match under rep risky:
    case True{} _ _:
      Reread{"action confidence is under the floor; re-read or ask instead of acting"}
    case _ True{} _:
      Skip{"the chosen action repeats an attempt the state already records failing; not taking it again"}
    case _ _ True{}:
      Confirm{a, "risk is at the top level and the goal did not ask for it"}
    case _ _ _:
      Act{a}

# `none` (a real decision — no listed action fits) and None{} (a decision
# string no action owns) are different rows with different reasons, the way
# the old dispatch split them.
def route.chosen(a: Maybe<&2, A.Action>, is_none: Bool, +confidence: F32, repeats: P.Answer, asked: P.Answer, risk: P.Answer) -> Route:
  match a is_none:
    case _ True{}:
      Stop{"Classify reported that no listed action fits the current state."}
    case None{} _:
      Stop{"Classify returned a decision that names no action."}
    case Some{+act} _:
      route.gate(
        under_floor(act, confidence),
        noul_above(repeats, repeats_floor()),
        Bool.and(scored_top(risk, risk_top()), unasked(asked)),
        act)

# The `action` answer's own case decides the step. A missing or mistyped
# answer halts the loop rather than falling through to a generation it never
# chose — #32's case.
def route.action(+action: P.Answer, repeats: P.Answer, asked: P.Answer, risk: P.Answer) -> Route:
  match action:
    case P.Chosen{+choice, +confidence}:
      route.chosen(A.parse_action(choice), String.eq(choice, "none"), confidence, repeats, asked, risk)
    case P.Missing{+reason}:
      Stop{"Classify returned no answer: " ++ reason}
    case P.Scored{+score, confidence}:
      Stop{"Classify answered 'action' with a score (" ++ F32.show(score) ++ "), not a choice."}
    case P.Nouled{+probability}:
      Stop{"Classify answered 'action' with a noul (" ++ F32.show(probability) ++ "), not a choice."}

# The whole table: the step's typed answers in, the loop's route out.
def route(a: LoopAnswers) -> Route:
  match a:
    case Ans{+action, blocked, repeats, asked, risk, progress}:
      route.action(action, repeats, asked, risk)

# ------------------------------------------------------------------------------
# The edit anchor: a Choice over line ids instead of transcribed text
# ------------------------------------------------------------------------------
# apply_edit's dominant failure is fabrication: a generative model asked to
# copy a file's bytes verbatim into `old_string` invents text that is not
# there (#23). Jev generates nothing, so it cannot emit wrong text. The
# line-by-line search cookbook turns that into the anchor: tag each line with
# an id, rank the ids with one Choice, and let a Noul say whether the file
# holds the thing to change at all. Read already tags the lines — the "N\t"
# prefixes are the ids — and code takes the chosen line's exact bytes from
# the file, which is where fabrication stops being recoverable and becomes
# impossible. The generative model writes only `new_string`, the part that is
# genuinely new.
#
# The picks run inside apply_edit rather than beside `action` in questions():
# their options depend on which file the edit targets, which only exists once
# the edit starts. The thresholds still sit here — a threshold reviews beside
# the question it reads (rule 7), not beside the call site.

# Lines an anchor window spans — under the 255-option cap a Choice enforces.
def anchor_page() -> Nat: 200n

# One row of a Read page ("N<TAB>line") as a Choice option: the line number is
# the label and the line's text the description — the same shape the cookbook
# tags its document with. A row without a tab carries no id (tool warnings
# are the only ones a page can hold) and is dropped rather than offered.
def page_option.of(ok: Bool, +id: String, +desc: String) -> Maybe<&2, P.OptionPair>:
  match ok:
    case False{}:
      None{}
    case True{}:
      Some{P.Opt{id, desc}}

# List.head's Maybe is matched inside a helper on a parameter, the workaround
# every computed scrutinee in this codebase takes.
def head_or(+d: String, m: Maybe<&2, String>) -> String:
  match m:
    case Some{+s}:
      s
    case None{}:
      d

def page_option.with(+id: String, +desc: String, +line: String) -> Maybe<&2, P.OptionPair>:
  page_option.of(
    Bool.and(String.contains(line, "\t"), Bool.not(String.is_empty(id))),
    id, desc)

# The line's text may itself hold tabs, so the description is the fields after
# the first re-joined rather than the second field alone.
def page_option(+line: String) -> Maybe<&2, P.OptionPair>:
  +parts = String.split(line, '\t')
  page_option.with(
    head_or("", List.head(&2, String, parts)),
    String.join(List.tail(&2, String, parts), "\t"),
    line)

def page_options.put.of(o: Maybe<&2, P.OptionPair>, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match o:
    case Some{+opt}:
      opt <> acc
    case None{}:
      acc

def page_options.put(line: String, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  page_options.put.of(page_option(line), acc)

# The helper that turns a read page into Choice options. A window is always
# under the cap already, but take no chances: the Choice refuses more than
# 255 options.
def page_options(+page: String) -> List<&2, P.OptionPair>:
  List.take(&2, P.OptionPair,
    List.foldr(~&2, ~String, ~List<&2, P.OptionPair>, ~page_options.put,
      String.lines(page), {Nil{} : List<&2, P.OptionPair>}),
    255n)

# One tracked file as a Choice option. The description repeats the path — the
# C loop reads each file's first line for one, and the twin takes the cheaper
# summary the name already gives.
def listing_option.of(ok: Bool, +path: String, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match ok:
    case True{}:
      P.Opt{path, path} <> acc
    case False{}:
      acc

def listing_option(+path: String, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  listing_option.of(Bool.not(String.is_empty(String.trim(path))), path, acc)

# foldr's element function is affine, and one path serves the trim check and
# the option both, so the listing folds by hand.
def listing_options.go(+ls: List<&2, String>, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match ls:
    case Nil{}:
      List.reverse(&2, P.OptionPair, acc)
    case +h <> t:
      listing_options.go(t, listing_option(h, acc))

# The `none` escape hatch always keeps a slot — a Choice's probabilities sum
# to one, so without it Jev must name a file even when none hold the change.
def listing_options(+listing: String) -> List<&2, P.OptionPair>:
  List.append(&2, P.OptionPair,
    List.take(&2, P.OptionPair,
      listing_options.go(String.lines(listing), {Nil{} : List<&2, P.OptionPair>}),
      254n),
    [P.Opt{"none", "No listed file holds the code the change belongs in"}])

# A window's label is the line number it starts at — parseable straight back
# with U32.read — and its description the span it covers.
def window_option(+start: Nat, +nlines: Nat, +page: Nat) -> P.OptionPair:
  P.Opt{
    U32.show(U32.from_nat(Nat.add(1n, start))),
    "lines " ++ U32.show(U32.from_nat(Nat.add(1n, start))) ++ " to " ++
      U32.show(U32.from_nat(Nat.min(Nat.add(start, page), nlines)))
  }

# fuel is the window count — one option per `page` lines — so the self-call
# shrinks it while `start` steps forward a page at a time.
def window_options.go(fuel: Nat, +start: Nat, +nlines: Nat, +page: Nat, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match fuel:
    case 0n:
      List.reverse(&2, P.OptionPair, acc)
    case 1n+f:
      window_options.go(f, Nat.add(start, page), nlines, page,
        window_option(start, nlines, page) <> acc)

def window_options(+nlines: Nat, +page: Nat) -> List<&2, P.OptionPair>:
  List.append(&2, P.OptionPair,
    window_options.go(Nat.div(Nat.sub(Nat.add(nlines, page), 1n), page),
      0n, nlines, page, {Nil{} : List<&2, P.OptionPair>}),
    [P.Opt{"none", "The code to change is not in any of these ranges"}])

# Which file the change belongs in — a closed set, so it is a Choice, and the
# file picked is always one the options listed.
def edit_file_questions(+listing: String) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "file_to_edit",
      "Which single file holds the code the requested change needs to modify?",
      listing_options(listing)
    }
  ]

# Past the option cap the cookbook pages the ids: one Choice picks a window
# of lines and a second ranks the lines inside it.
def edit_window_questions(+path: String, +nlines: Nat, +page: Nat) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "edit_window",
      "The change belongs in " ++ path ++ ", which is longer than one page of options. Which range of lines is most likely to hold the code the requested change modifies?",
      window_options(nlines, page)
    }
  ]

# The anchor itself: one Choice over the window's line ids and one Noul for
# whether the file holds the thing to change at all — the no-match outcome a
# sum-to-one Choice cannot express on its own.
def anchor_questions(+path: String, +page: String) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "edit_anchor",
      "Which single line of " ++ path ++ " does the requested change belong at? The option's name is the line number; its description is the line's exact text.",
      page_options(page)
    },
    P.NoulQ{
      "edit_present",
      "Does " ++ path ++ " contain the code the requested change needs to modify?"
    }
  ]

# `file_to_edit` and `edit_window` confidence floors. Both pick a candidate to
# look inside rather than an action to take, so they sit lower than the
# action floors: a wrong pick costs one more Jev call before the sentinel
# fallback, not a write. Not yet tuned on labeled data.
def edit_file_floor() -> F32: 0.40
def edit_window_floor() -> F32: 0.40

# `edit_anchor` confidence floor: under it the Choice is guessing and the
# sentinel draft takes over. Not yet tuned on labeled data.
def anchor_choice_floor() -> F32: 0.60

# `edit_present` floor. The line-by-line cookbook measured a present answer at
# or above 0.9 and an absent one at or below 0.05 on the Noul, so 0.5
# separates the cases it measured; treat it as a starting point to re-measure
# on this repository.
def anchor_noul_floor() -> F32: 0.50

# The single-question picks: a Choice answer reads as its label when it is
# confident enough, and everything else — `none`, a low confidence, a missing
# or mistyped answer — reads as no pick, which sends the caller down the
# sentinel fallback.
def pick_label.of(is_none: Bool, low: Bool, +label: String) -> Maybe<&2, String>:
  match is_none low:
    case True{} _:
      None{}
    case _ True{}:
      None{}
    case _ _:
      Some{label}

def pick_label(+a: P.Answer, +floor: F32) -> Maybe<&2, String>:
  match a:
    case P.Chosen{+choice, +confidence}:
      pick_label.of(String.eq(choice, "none"), F32.is_lt(confidence, floor), choice)
    case _:
      None{}

def edit_file_pick(+a: P.Answer) -> Maybe<&2, String>:
  pick_label(a, edit_file_floor())

def edit_window_pick.of(m: Maybe<&2, String>) -> Maybe<&2, U32>:
  match m:
    case Some{+label}:
      U32.read(label)
    case None{}:
      None{}

# The window answer reads as the line its range starts at; anything unusable
# is no pick.
def edit_window_pick(+a: P.Answer) -> Maybe<&2, U32>:
  edit_window_pick.of(pick_label(a, edit_window_floor()))

# What the anchor answers route to: Anchor is the line the change belongs at —
# code slices its bytes out of the file — and AnchorBack hands the edit back
# to the sentinel draft with the reason the anchor did not hold.
type AnchorRoute is Data:
  Anchor{line: U32}
  AnchorBack{reason: String}

# A Noul under the floor reads as absent; a missing or mistyped answer reads
# the same — it cannot show the file holds the code, which is the safe
# direction for a gate.
def noul_below(+a: P.Answer, +floor: F32) -> Bool:
  match a:
    case P.Nouled{+probability}:
      F32.is_lt(probability, floor)
    case _:
      True{}

# The gate rows, as Bool scrutinees computed by the caller so each row can be
# pinned by a law below — the same shape route.gate takes.
def anchor_route.gate(absent: Bool, low: Bool, line: U32) -> AnchorRoute:
  match absent low:
    case True{} _:
      AnchorBack{"the file does not contain the code the change needs"}
    case _ True{}:
      AnchorBack{"the anchor Choice was not confident enough to trust"}
    case _ _:
      Anchor{line}

def anchor_route.picked(m: Maybe<&2, U32>, +confidence: F32, +noul: P.Answer) -> AnchorRoute:
  match m:
    case Some{line}:
      anchor_route.gate(
        noul_below(noul, anchor_noul_floor()),
        F32.is_lt(confidence, anchor_choice_floor()),
        line)
    case None{}:
      AnchorBack{"the anchor Choice named no line of the file"}

def anchor_route(+choice: P.Answer, +noul: P.Answer) -> AnchorRoute:
  match choice:
    case P.Chosen{+label, +confidence}:
      anchor_route.picked(U32.read(label), confidence, noul)
    case P.Missing{+reason}:
      AnchorBack{"Classify returned no anchor: " ++ reason}
    case _:
      AnchorBack{"'edit_anchor' answered with the wrong type"}

# ------------------------------------------------------------------------------
# The laws: each row is what it claims to be
# ------------------------------------------------------------------------------
# The gate rows are proved over every action; moving an arm or weakening a row
# fails the build here. Rows through route.chosen prove too, because the
# `none`/unparseable paths never reach an opaque F32 comparison.

# LAW: confidence under the floor reroutes every action to a re-read
law Selector.under_floor_rereads:
  for a: A.Action
  {route.gate(True{}, False{}, False{}, a) == Reread{"action confidence is under the floor; re-read or ask instead of acting"} : Route}
def Selector.under_floor_rereads(a): {==}

# LAW: repeats high skips the chosen action
law Selector.repeats_skips:
  for a: A.Action
  {route.gate(False{}, True{}, False{}, a) == Skip{"the chosen action repeats an attempt the state already records failing; not taking it again"} : Route}
def Selector.repeats_skips(a): {==}

# LAW: top-level risk the goal did not ask for is confirmed before running
law Selector.risk_confirms:
  for a: A.Action
  {route.gate(False{}, False{}, True{}, a) == Confirm{a, "risk is at the top level and the goal did not ask for it"} : Route}
def Selector.risk_confirms(a): {==}

# LAW: a clear step acts on the choice
law Selector.clear_acts:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, a) == Act{a} : Route}
def Selector.clear_acts(a): {==}

# LAW: the floor row wins over the later rows, matching the table's order
law Selector.floor_first:
  for a: A.Action
  {route.gate(True{}, True{}, True{}, a) == Reread{"action confidence is under the floor; re-read or ask instead of acting"} : Route}
def Selector.floor_first(a): {==}

# LAW: `none` halts with its reason, whatever the other answers say
law Selector.none_halts:
  {route(Ans{P.Chosen{"none", 0.9}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}})
    == Stop{"Classify reported that no listed action fits the current state."} : Route}
def Selector.none_halts(): {==}

# LAW: a decision naming no action halts with its reason
law Selector.unparseable_halts:
  {route(Ans{P.Chosen{"bogus", 0.9}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}})
    == Stop{"Classify returned a decision that names no action."} : Route}
def Selector.unparseable_halts(): {==}

# LAW: a missing answer halts with the reason it carried
law Selector.missing_halts:
  {route(Ans{P.Missing{"rate limited"}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}})
    == Stop{"Classify returned no answer: rate limited"} : Route}
def Selector.missing_halts(): {==}

# LAW: a file that does not hold the code sends the edit back to the draft
law Selector.anchor_absent_backs:
  for line: U32
  {anchor_route.gate(True{}, False{}, line) == AnchorBack{"the file does not contain the code the change needs"} : AnchorRoute}
def Selector.anchor_absent_backs(line): {==}

# LAW: absence wins over confidence — the gate checks presence first
law Selector.anchor_absent_first:
  for line: U32
  {anchor_route.gate(True{}, True{}, line) == AnchorBack{"the file does not contain the code the change needs"} : AnchorRoute}
def Selector.anchor_absent_first(line): {==}

# LAW: an under-floor anchor sends the edit back to the draft
law Selector.anchor_low_backs:
  for line: U32
  {anchor_route.gate(False{}, True{}, line) == AnchorBack{"the anchor Choice was not confident enough to trust"} : AnchorRoute}
def Selector.anchor_low_backs(line): {==}

# LAW: a confident anchor over a present file keeps its line
law Selector.anchor_keeps:
  for line: U32
  {anchor_route.gate(False{}, False{}, line) == Anchor{line} : AnchorRoute}
def Selector.anchor_keeps(line): {==}

# LAW: a missing anchor answer backs out with the reason it carried
law Selector.anchor_missing_backs:
  {anchor_route(P.Missing{"rate limited"}, P.Nouled{0.9})
    == AnchorBack{"Classify returned no anchor: rate limited"} : AnchorRoute}
def Selector.anchor_missing_backs(): {==}

# LAW: an anchor naming no line backs out
law Selector.anchor_unparsable_backs:
  {anchor_route(P.Chosen{"bogus", 0.9}, P.Nouled{0.9})
    == AnchorBack{"the anchor Choice named no line of the file"} : AnchorRoute}
def Selector.anchor_unparsable_backs(): {==}

# ------------------------------------------------------------------------------
# The table, exercised: each row's expected output is pinned by #| below
# ------------------------------------------------------------------------------
def show_route(r: Route) -> String:
  match r:
    case Act{+action}:
      "act(" ++ A.show_action(action) ++ ")"
    case Reread{reason}:
      "reread"
    case Skip{reason}:
      "skip"
    case Confirm{+action, reason}:
      "confirm(" ++ A.show_action(action) ++ ")"
    case Stop{+reason}:
      "halt(" ++ reason ++ ")"

def probe(+label: String, a: LoopAnswers) -> IO(Unit):
  IO.print(label ++ " -> " ++ show_route(route(a)))

def show_opt(o: P.OptionPair) -> String:
  match o:
    case P.Opt{+label, +desc}:
      label ++ " => " ++ desc

def show_anchor_route(r: AnchorRoute) -> String:
  match r:
    case Anchor{+line}:
      "anchor(" ++ U32.show(line) ++ ")"
    case AnchorBack{+reason}:
      "back(" ++ reason ++ ")"

def aprobe(+label: String, r: AnchorRoute) -> IO(Unit):
  IO.print(label ++ " -> " ++ show_anchor_route(r))

def main() -> IO(Unit):
  do IO<Unit>:
    u1 : Unit <- probe("confident read_code",       Ans{P.Chosen{"read_code", 0.9},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u2 : Unit <- probe("mid-confidence read_code",  Ans{P.Chosen{"read_code", 0.5},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u3 : Unit <- probe("mid-confidence apply_edit", Ans{P.Chosen{"apply_edit", 0.5},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u4 : Unit <- probe("low-confidence answer",     Ans{P.Chosen{"generate_answer", 0.3}, P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u5 : Unit <- probe("repeats high",              Ans{P.Chosen{"search_code", 0.9},     P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u6 : Unit <- probe("top risk, unasked",         Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{1.8, 0.8}, P.Scored{0.1, 0.9}})
    u7 : Unit <- probe("top risk, asked",           Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{1.8, 0.8}, P.Scored{0.1, 0.9}})
    u8 : Unit <- probe("none",                      Ans{P.Chosen{"none", 0.9},            P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u9 : Unit <- probe("names no action",           Ans{P.Chosen{"bogus", 0.9},           P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u10 : Unit <- probe("missing",                  Ans{P.Missing{"rate limited"},        P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})
    u11 : Unit <- IO.print("page options -> " ++ List.show(~&2, ~P.OptionPair, ~show_opt, page_options("3\tthree\n7\tseven\nno tab here\n12\ttwelve")))
    u12 : Unit <- IO.print("window options -> " ++ List.show(~&2, ~P.OptionPair, ~show_opt, window_options(560n, 200n)))
    u13 : Unit <- aprobe("confident anchor, present", anchor_route(P.Chosen{"7", 0.9}, P.Nouled{0.95}))
    u14 : Unit <- aprobe("confident anchor, absent",  anchor_route(P.Chosen{"7", 0.9}, P.Nouled{0.1}))
    u15 : Unit <- aprobe("low-confidence anchor",     anchor_route(P.Chosen{"7", 0.3}, P.Nouled{0.95}))
    u16 : Unit <- aprobe("unparsable anchor",         anchor_route(P.Chosen{"bogus", 0.9}, P.Nouled{0.95}))
    aprobe("missing anchor",                          anchor_route(P.Missing{"rate limited"}, P.Nouled{0.95}))

#|confident read_code -> act(read_code)
#|mid-confidence read_code -> act(read_code)
#|mid-confidence apply_edit -> reread
#|low-confidence answer -> reread
#|repeats high -> skip
#|top risk, unasked -> confirm(apply_edit)
#|top risk, asked -> act(apply_edit)
#|none -> halt(Classify reported that no listed action fits the current state.)
#|names no action -> halt(Classify returned a decision that names no action.)
#|missing -> halt(Classify returned no answer: rate limited)
#|page options -> [3 => three, 7 => seven, 12 => twelve]
#|window options -> [1 => lines 1 to 200, 201 => lines 201 to 400, 401 => lines 401 to 560, none => The code to change is not in any of these ranges]
#|confident anchor, present -> anchor(7)
#|confident anchor, absent -> back(the file does not contain the code the change needs)
#|low-confidence anchor -> back(the anchor Choice was not confident enough to trust)
#|unparsable anchor -> back(the anchor Choice named no line of the file)
#|missing anchor -> back(Classify returned no anchor: rate limited)
