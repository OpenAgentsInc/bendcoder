import Base
import ./agent_primitives.bend as P
import ./action.bend as A
import ./reads.bend as R

# ==============================================================================
# Bendcoder Selector: the question set, the thresholds, and the answers-to-action
# table, in one reviewable module (design rules 7 and 8)
# ==============================================================================
# Rule 8: the questions Bendcoder asks and the thresholds that consume them must
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
#   `apply_edit` with nothing read yet                 Re-read; edits draft
#                                                      against code already read
#   `generate_answer` on too little info, nothing read Re-read; answering now
#                                                      is a guess
#   otherwise                                          Act on the choice
#
# In Bend the table is a match over typed answers, which is where
# exhaustiveness earns its keep: every branch is checked, and `LoopAnswers`
# gives each question a field that every consumer's pattern must bind — adding
# a question and forgetting to route it is a compile error, not a dead row.
# This was route_decision's table while the loop lived in bendcoder_agent.c; it
# is the only copy now.

# ------------------------------------------------------------------------------
# The question set
# ------------------------------------------------------------------------------
# `read_code` is offered first while reads are live; once the picker's own
# refusals say every remaining file is judged not worth reading it leaves the
# list, so the action Choice must spend the step on an action that can act.
# `plan` is offered only while no worklist exists: a second `plan` action
# would overwrite the items already checked off, which is progress the state
# cannot recover. The model can still finish or edit without it.
def action_options.plan_opt(+has_plan: Bool) -> List<&2, P.OptionPair>:
  match has_plan:
    case True{}:
      {Nil{} : List<&2, P.OptionPair>}
    case False{}:
      [P.Opt{A.show_action(A.Plan{}), "Decompose the goal into a worklist of concrete hunks, each naming the file it lands in — for a change with several edit sites"}]

def action_options.rest(+has_plan: Bool) -> List<&2, P.OptionPair>:
  List.append(&2, P.OptionPair,
    List.append(&2, P.OptionPair,
      [
        P.Opt{A.show_action(A.SearchCode{}), "Search the repository for a literal string to find which files are relevant"},
        P.Opt{A.show_action(A.RunBuild{}), "Run build, compile, or test command to check if code works or reproduces an error"},
        P.Opt{A.show_action(A.ApplyEdit{}), "Change the code on disk: the fix is understood and a concrete edit to a known file — or a whole new file — can be written now"}
      ],
      action_options.plan_opt(has_plan)),
    [
      P.Opt{A.show_action(A.GenerateAnswer{}), "Synthesize code, write a patch, or generate a fix using the LLM"},
      P.Opt{A.show_action(A.TaskComplete{}), "The task is successfully resolved, verified, and complete — no `plan` item unchecked"},
      P.Opt{"none", "No listed action fits: the state does not yet support a next step"}
    ])

def action_options(+reads_out: Bool, +has_plan: Bool) -> List<&2, P.OptionPair>:
  match reads_out:
    case True{}:
      action_options.rest(has_plan)
    case False{}:
      P.Opt{A.show_action(A.ReadCode{}), "Read source code or repository files to understand context or inspect implementations"} <> action_options.rest(has_plan)

# One entry per field of LoopAnswers, in the same order. `reads_out` drops
# `read_code` from the options when the file Choice has already refused every
# remaining file — a picker cannot choose an action it is not offered, so the
# loop stops spending steps converting read_code decisions into searches.
# `has_plan` drops `plan` the same way once a worklist exists.
def questions(+reads_out: Bool, +has_plan: Bool) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "action",
      "Given `directive`, `program`, `observations`, `facts` and `plan` — the worklist, where '[ ]' is owed and '[x]' is done — what is the single next best action to advance or verify the task? When `plan` lists items, work the next unchecked one rather than re-orienting from `directive` alone.",
      action_options(reads_out, has_plan)
    },
    P.NoulQ{
      "is_blocked",
      "Is the task blocked by an error or a failing `facts.verification`?"
    },
    P.NoulQ{
      "repeats",
      "Would the next action repeat something `observations` or `index.search_hits` already record having tried without success?"
    },
    P.NoulQ{
      "needs_code_change",
      "Does satisfying `directive` require editing files in this repository, rather than only answering in prose?"
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
      "How close are `observations` and `facts.verification` to a fully verified resolution?",
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

# The under-floor run's per-decision check: a Chosen answer under the
# consequence-weighted floor — the same `under` the route's first row tests,
# so an apply_edit in the band between the two floors counts as the reroute it
# produces rather than reading as confident. Anything not a usable choice is
# not a weak decision at all: the route's own rows halt it.
def answer_under.of(m: Maybe<&2, A.Action>, +confidence: F32) -> Bool:
  match m:
    case Some{+act}:
      under_floor(act, confidence)
    case None{}:
      False{}

def answer_under(+a: P.Answer) -> Bool:
  match a:
    case P.Chosen{+choice, +confidence}:
      answer_under.of(A.parse_action(choice), confidence)
    case _:
      False{}

# The actions an under-floor decision may still run once the floor is spent.
# `task_complete` is the exception: a weak "done" is never worth acting on —
# the reads the floor buys can only make a real done more confident, while a
# wrong one ends the run on a guess.
def floor_acts(a: A.Action) -> Bool:
  match a:
    case A.TaskComplete{}:
      False{}
    case _:
      True{}

# The same predicate on the unparsed answer, for the loop's tally: it must
# know whether this under-floor decision will act before it decides what the
# step counts as.
def floor_acts_answer(+a: P.Answer) -> Bool:
  match a:
    case P.Chosen{+choice, confidence}:
      Bool.not(String.eq(choice, "task_complete"))
    case _:
      False{}

# The retry rule, on the unparsed answer for the loop's tally: a Chosen
# apply_edit while the last verification stands failed is a retry informed by
# the error already in the state — it acts under the floor, and it is not a
# reroute, so it does not bump the under-floor run either.
def answer_retry_edit(+a: P.Answer, failed: Bool) -> Bool:
  match a:
    case P.Chosen{+choice, confidence}:
      Bool.and(failed, String.eq(choice, "apply_edit"))
    case _:
      False{}

# The landed-read rule, on the unparsed answer for the loop's tally: a Chosen
# apply_edit after the read a refused edit named has been served is a
# resumption informed by pages already in the state — it acts under the
# floor, and it is not a reroute, so it does not bump the under-floor run
# either. The route reads the same flag from the Book.
def answer_met_edit(+a: P.Answer, met: Bool) -> Bool:
  match a:
    case P.Chosen{+choice, confidence}:
      Bool.and(met, String.eq(choice, "apply_edit"))
    case _:
      False{}

# The route a spent floor produces: act, except `done`, which keeps
# re-reading — a persistent weak preference gets the guarded path, a
# persistent weak completion gets the flail halt.
def floor_out(a: A.Action) -> Route:
  match a:
    case A.TaskComplete{}:
      Reread{"action confidence is under the floor and 'done' is the one answer that cannot be risked; re-reading instead"}
    case _:
      Act{a}

# The table's gated rows. A match scrutinizes only parameters, so the
# comparisons arrive as Bool scrutinees computed by the caller — which is also
# what lets the laws below pin each row, since the F32 comparisons are opaque
# to the checker. The last two rows are the C table's loop guards: an edit is
# only drafted against code already read, and an answer on too little
# information with nothing read yet is a guess — both reroute to a read.
# `spent` is the loop's own fact — `floor_reads` consecutive under-floor
# reroutes already bought their reads — which the second row tests: a
# persistent weak preference acts through its guarded path rather than
# rerouting a third time into reads that stopped being able to help.
# `read_dead` is the first row for the mirror-image case: the file Choice
# declined enough times that a read_code decision is a read into a picker
# that already said no — the loop searches instead of asking again.
# `unfin` is the worklist's row: a task_complete while a markable plan item
# stands unchecked reroutes toward it — the selector routes toward the next
# unchecked item rather than letting the model re-derive orientation from the
# issue text, and `item` is the hunk the reason names. Only a task_complete
# sets it, so it cannot block the work itself.
# An open plan item gates finishing, not working. Routing it on `unfin` alone
# rerouted every action, including the edits that would discharge the item --
# which is what Selector.open_plan_acts caught. `a` cannot join the match's
# scrutinees without a tenth column on every row, so the row hands it here.
def plan_gate(a: A.Action, +item: String) -> Route:
  match a:
    case A.TaskComplete{}:
      Reread{"the plan still lists '" ++ item ++ "' unchecked; work the plan rather than finishing"}
    case other:
      Act{other}

def route.gate(under: Bool, spent: Bool, rep: Bool, risky: Bool, stuck: Bool, blind_edit: Bool, blind_answer: Bool, read_dead: Bool, unfin: Bool, +item: String, a: A.Action) -> Route:
  match under spent rep risky stuck blind_edit blind_answer read_dead unfin:
    case _ _ _ _ _ _ _ True{} _:
      Skip{"the file Choice keeps declining — every remaining file is judged not worth reading"}
    case True{} False{} _ _ _ _ _ _ _:
      Reread{"action confidence is under the floor; re-read or ask instead of acting"}
    case True{} True{} _ _ _ _ _ _ _:
      floor_out(a)
    case _ _ True{} _ _ _ _ _ _:
      Skip{"the chosen action repeats an attempt the state already records failing; not taking it again"}
    case _ _ _ True{} _ _ _ _ _:
      Confirm{a, "risk is at the top level and the goal did not ask for it"}
    case _ _ _ _ True{} _ _ _ _:
      Reread{"several searches in a row found nothing; reading instead"}
    case _ _ _ _ _ True{} _ _ _:
      Reread{"an edit is only drafted against code already read; reading first"}
    case _ _ _ _ _ _ True{} _ _:
      Reread{"too little information to answer and nothing read yet; reading first"}
    case _ _ _ _ _ _ _ _ True{}:
      plan_gate(a, item)
    case _ _ _ _ _ _ _ _ _:
      Act{a}

# The two loop guards key on the action's own identity, which a match over
# the Action gives — the C table compares the enum the same way.
def act_is_edit(+a: A.Action) -> Bool:
  match a:
    case A.ApplyEdit{}:
      True{}
    case _:
      False{}

def act_is_answer(+a: A.Action) -> Bool:
  match a:
    case A.GenerateAnswer{}:
      True{}
    case _:
      False{}

def act_is_search(+a: A.Action) -> Bool:
  match a:
    case A.SearchCode{}:
      True{}
    case _:
      False{}

def act_is_read(+a: A.Action) -> Bool:
  match a:
    case A.ReadCode{}:
      True{}
    case _:
      False{}

def act_is_complete(+a: A.Action) -> Bool:
  match a:
    case A.TaskComplete{}:
      True{}
    case _:
      False{}

# The open-item Maybe the loop hands in, split for the gate: `unfin` is the
# row's Bool scrutinee — a Maybe cannot be one — and `item` is the hunk the
# row's reason names.
def open_some(m: Maybe<&2, String>) -> Bool:
  match m:
    case Some{s}:
      True{}
    case None{}:
      False{}

def open_item(m: Maybe<&2, String>) -> String:
  match m:
    case Some{+s}:
      s
    case None{}:
      ""

# The has_enough_info noul's counterpart in this question set: progress_score
# is a 0-2 rubric whose bottom band ("just starting / investigating") ends at
# 1.0, so under it an answer reads as a guess — the same direction
# BENDCODER_INFO_FLOOR points the C table's guard row.
def answer_info_floor() -> F32: 1.0

def progress_low(+a: P.Answer) -> Bool:
  match a:
    case P.Scored{+score, confidence}:
      F32.is_lt(score, answer_info_floor())
    case _:
      True{}

# `none` (a real decision — no listed action fits) and None{} (a decision
# string no action owns) are different rows with different reasons, the way
# the old dispatch split them. `unread` is the loop's "nothing read yet" —
# read_phase == 0 in the C table, which the two guard rows test. `reads_out`
# is the picker's own verdict that nothing left is worth reading, which turns
# a read_code decision into the dead-read row. `met` is the Book's record
# that the read a refused edit named has landed — like a standing verify
# failure it lets an under-floor apply_edit act, because the read the floor
# exists to buy has already been bought.
# `open` is the plan's next unchecked hunk — the first item still owed that
# names a tracked file — which the last gate row reroutes a premature
# task_complete toward. Items naming no repository file render but cannot
# gate: a worklist the loop cannot mark must not become one it cannot end.
def route.chosen(a: Maybe<&2, A.Action>, is_none: Bool, +confidence: F32, repeats: P.Answer, asked: P.Answer, risk: P.Answer, progress: P.Answer, +unread: Bool, +stuck: Bool, +spent: Bool, +reads_out: Bool, +failed: Bool, +met: Bool, +open: Maybe<&2, String>) -> Route:
  match a is_none:
    case _ True{}:
      Stop{"Classify reported that no listed action fits the current state."}
    case None{} _:
      Stop{"Classify returned a decision that names no action."}
    case Some{+act} _:
      route.gate(
        Bool.and(under_floor(act, confidence),
          Bool.not(Bool.and(act_is_edit(act), Bool.or(failed, met)))),
        spent,
        noul_above(repeats, repeats_floor()),
        Bool.and(scored_top(risk, risk_top()), unasked(asked)),
        Bool.and(act_is_search(act), stuck),
        Bool.and(act_is_edit(act), unread),
        Bool.and(Bool.and(act_is_answer(act), unread), progress_low(progress)),
        Bool.and(act_is_read(act), reads_out),
        Bool.and(act_is_complete(act), open_some(open)),
        open_item(open),
        act)

# The `action` answer's own case decides the step. A missing or mistyped
# answer halts the loop rather than falling through to a generation it never
# chose — #32's case.
def route.action(+action: P.Answer, repeats: P.Answer, asked: P.Answer, risk: P.Answer, progress: P.Answer, +unread: Bool, +stuck: Bool, +spent: Bool, +reads_out: Bool, +failed: Bool, +met: Bool, +open: Maybe<&2, String>) -> Route:
  match action:
    case P.Chosen{+choice, +confidence}:
      route.chosen(A.parse_action(choice), String.eq(choice, "none"), confidence, repeats, asked, risk, progress, unread, stuck, spent, reads_out, failed, met, open)
    case P.Missing{+reason}:
      Stop{"Classify returned no answer: " ++ reason}
    case P.Scored{+score, confidence}:
      Stop{"Classify answered 'action' with a score (" ++ F32.show(score) ++ "), not a choice."}
    case P.Nouled{+probability}:
      Stop{"Classify answered 'action' with a noul (" ++ F32.show(probability) ++ "), not a choice."}

# The whole table: the step's typed answers in, the loop's route out. `spent`
# is the Book's under-floor run — the reroutes the floor already bought.
# `reads_out` is its declined-pick run — the reads the picker refused.
# `met` is its discharged want — the read a refused edit named, landed.
# `open` is the plan's next unchecked hunk, which is the loop's own fact too —
# the state carries the worklist, and next_open reads it.
def route(a: LoopAnswers, +unread: Bool, +stuck: Bool, +spent: Bool, +reads_out: Bool, +failed: Bool, +met: Bool, +open: Maybe<&2, String>) -> Route:
  match a:
    case Ans{+action, blocked, repeats, asked, risk, +progress}:
      route.action(action, repeats, asked, risk, progress, unread, stuck, spent, reads_out, failed, met, open)

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

# A path already read to the end drops out of the read picker's options —
# bendcoder_agent.c's exhausted flag, here keyed on the Book's done list. The
# check and the option both need the path, so it folds by hand like
# listing_options does.
def read_option.of(skip: Bool, +path: String, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match skip:
    case True{}:
      acc
    case False{}:
      P.Opt{path, path} <> acc

def read_option(+path: String, +done: List<&2, String>, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  read_option.of(
    Bool.or(String.is_empty(String.trim(path)), R.str_member(done, path)),
    path, acc)

def read_options.go(+ls: List<&2, String>, +done: List<&2, String>, acc: List<&2, P.OptionPair>) -> List<&2, P.OptionPair>:
  match ls:
    case Nil{}:
      List.reverse(&2, P.OptionPair, acc)
    case +h <> t:
      read_options.go(t, done, read_option(h, done, acc))

def read_options(+listing: String, +done: List<&2, String>) -> List<&2, P.OptionPair>:
  List.append(&2, P.OptionPair,
    List.take(&2, P.OptionPair,
      read_options.go(String.lines(listing), done, {Nil{} : List<&2, P.OptionPair>}),
      254n),
    [P.Opt{"none", "No listed file is worth reading for this goal"}])

# Which file the change belongs in — a closed set, so it is a Choice, and the
# file picked is always one the options listed.
def edit_file_questions(+listing: String) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "file_to_edit",
      "Which single file in `index.paths` holds the code the requested change needs to modify?",
      listing_options(listing)
    }
  ]

# Which file to read next — the same closed-set shape as file_to_edit, but
# its options exclude the files already read to the end. The C loop asks Jev
# this after the README context read; the Book's done list is its
# exhausted-flag set.
def read_file_questions(+listing: String, +done: List<&2, String>) -> List<&2, P.Question>:
  [
    P.ChoiceQ{
      "file_to_read",
      "Which single file in `index.paths` is most worth reading next to advance or verify the task?",
      read_options(listing, done)
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

# `file_to_read` shares the file picker's floor: a wrong pick costs a page of
# context, not a write. Not yet tuned on labeled data.
def read_file_floor() -> F32: 0.40

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

def read_file_pick(+a: P.Answer) -> Maybe<&2, String>:
  pick_label(a, read_file_floor())

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

# LAW: a read into a picker that keeps declining is sent to a search, ahead
# of every other row
law Selector.dead_read_seeks:
  for a: A.Action
  {route.gate(True{}, False{}, False{}, False{}, False{}, False{}, False{}, True{}, False{}, "", a) == Skip{"the file Choice keeps declining — every remaining file is judged not worth reading"} : Route}
def Selector.dead_read_seeks(a): {==}

# LAW: confidence under the floor reroutes every action to a re-read
law Selector.under_floor_rereads:
  for a: A.Action
  {route.gate(True{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, "", a) == Reread{"action confidence is under the floor; re-read or ask instead of acting"} : Route}
def Selector.under_floor_rereads(a): {==}

# LAW: a spent floor lets a persistent weak edit through the guarded path
law Selector.floor_spent_edit_acts:
  {route.gate(True{}, True{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, "", A.ApplyEdit{}) == Act{A.ApplyEdit{}} : Route}
def Selector.floor_spent_edit_acts(): {==}

# LAW: a spent floor never lets a weak "done" act — it keeps re-reading
law Selector.floor_spent_done_rereads:
  {route.gate(True{}, True{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, "", A.TaskComplete{}) == Reread{"action confidence is under the floor and 'done' is the one answer that cannot be risked; re-reading instead"} : Route}
def Selector.floor_spent_done_rereads(): {==}

# LAW: repeats high skips the chosen action
law Selector.repeats_skips:
  for a: A.Action
  {route.gate(False{}, False{}, True{}, False{}, False{}, False{}, False{}, False{}, False{}, "", a) == Skip{"the chosen action repeats an attempt the state already records failing; not taking it again"} : Route}
def Selector.repeats_skips(a): {==}

# LAW: top-level risk the goal did not ask for is confirmed before running
law Selector.risk_confirms:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, True{}, False{}, False{}, False{}, False{}, False{}, "", a) == Confirm{a, "risk is at the top level and the goal did not ask for it"} : Route}
def Selector.risk_confirms(a): {==}

# LAW: a stuck search re-reads instead of missing again
law Selector.stuck_rereads:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, False{}, True{}, False{}, False{}, False{}, False{}, "", a) == Reread{"several searches in a row found nothing; reading instead"} : Route}
def Selector.stuck_rereads(a): {==}

# LAW: an edit with nothing read yet re-reads first
law Selector.blind_edit_rereads:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, False{}, False{}, True{}, False{}, False{}, False{}, "", a) == Reread{"an edit is only drafted against code already read; reading first"} : Route}
def Selector.blind_edit_rereads(a): {==}

# LAW: an answer on too little information with nothing read re-reads first
law Selector.blind_answer_rereads:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, False{}, False{}, False{}, True{}, False{}, False{}, "", a) == Reread{"too little information to answer and nothing read yet; reading first"} : Route}
def Selector.blind_answer_rereads(a): {==}

# LAW: an unchecked plan item reroutes a premature task_complete toward it
law Selector.open_plan_rereads:
  {route.gate(False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, True{}, "edit tools_c.h", A.TaskComplete{})
    == Reread{"the plan still lists 'edit tools_c.h' unchecked; work the plan rather than finishing"} : Route}
def Selector.open_plan_rereads(): {==}

# LAW: open plan items gate no action but task_complete — the work acts on
law Selector.open_plan_acts:
  {route.gate(False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, True{}, "edit tools_c.h", A.ApplyEdit{})
    == Act{A.ApplyEdit{}} : Route}
def Selector.open_plan_acts(): {==}

# LAW: a clear step acts on the choice
law Selector.clear_acts:
  for a: A.Action
  {route.gate(False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, False{}, "", a) == Act{a} : Route}
def Selector.clear_acts(a): {==}

# LAW: the floor row wins over the later rows, matching the table's order
law Selector.floor_first:
  for a: A.Action
  {route.gate(True{}, False{}, True{}, True{}, True{}, True{}, True{}, False{}, False{}, "", a) == Reread{"action confidence is under the floor; re-read or ask instead of acting"} : Route}
def Selector.floor_first(a): {==}

# LAW: `none` halts with its reason, whatever the other answers say
law Selector.none_halts:
  {route(Ans{P.Chosen{"none", 0.9}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    == Stop{"Classify reported that no listed action fits the current state."} : Route}
def Selector.none_halts(): {==}

# LAW: a decision naming no action halts with its reason
law Selector.unparseable_halts:
  {route(Ans{P.Chosen{"bogus", 0.9}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    == Stop{"Classify returned a decision that names no action."} : Route}
def Selector.unparseable_halts(): {==}

# LAW: a missing answer halts with the reason it carried
law Selector.missing_halts:
  {route(Ans{P.Missing{"rate limited"}, P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{1.9, 0.9}, P.Scored{0.0, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
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

def probe(+label: String, a: LoopAnswers, unread: Bool, stuck: Bool, spent: Bool, reads_out: Bool, failed: Bool, met: Bool, +open: Maybe<&2, String>) -> IO(Unit):
  IO.print(label ++ " -> " ++ show_route(route(a, unread, stuck, spent, reads_out, failed, met, open)))

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
    u1 : Unit <- probe("confident read_code",       Ans{P.Chosen{"read_code", 0.9},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u2 : Unit <- probe("mid-confidence read_code",  Ans{P.Chosen{"read_code", 0.5},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u3 : Unit <- probe("mid-confidence apply_edit", Ans{P.Chosen{"apply_edit", 0.5},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u4 : Unit <- probe("low-confidence answer",     Ans{P.Chosen{"generate_answer", 0.3}, P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u5 : Unit <- probe("repeats high",              Ans{P.Chosen{"search_code", 0.9},     P.Nouled{0.1}, P.Nouled{0.9}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u6 : Unit <- probe("top risk, unasked",         Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{1.8, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u7 : Unit <- probe("top risk, asked",           Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{1.8, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u8 : Unit <- probe("none",                      Ans{P.Chosen{"none", 0.9},            P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u9 : Unit <- probe("names no action",           Ans{P.Chosen{"bogus", 0.9},           P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u10 : Unit <- probe("missing",                  Ans{P.Missing{"rate limited"},        P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u11 : Unit <- probe("edit, nothing read",       Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, True{}, False{}, False{}, False{}, False{}, False{}, None{})
    u12 : Unit <- probe("answer, nothing read",     Ans{P.Chosen{"generate_answer", 0.9}, P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, True{}, False{}, False{}, False{}, False{}, False{}, None{})
    u13 : Unit <- probe("edit, read done",          Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u14 : Unit <- probe("search, misses high",      Ans{P.Chosen{"search_code", 0.9},     P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, True{}, False{}, False{}, False{}, False{}, None{})
    u15 : Unit <- probe("search, first miss",       Ans{P.Chosen{"search_code", 0.9},     P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    ua : Unit <- probe("weak edit, floor spent",    Ans{P.Chosen{"apply_edit", 0.35},     P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, True{}, False{}, False{}, False{}, None{})
    ub : Unit <- probe("weak done, floor spent",    Ans{P.Chosen{"task_complete", 0.3},   P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, True{}, False{}, False{}, False{}, None{})
    uc : Unit <- probe("weak read, floor spent",    Ans{P.Chosen{"read_code", 0.3},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, True{}, False{}, False{}, False{}, None{})
    ud : Unit <- probe("read, reads out",           Ans{P.Chosen{"read_code", 0.9},       P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, True{}, False{}, False{}, None{})
    ue : Unit <- probe("edit, reads out",           Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, True{}, False{}, False{}, None{})
    uf : Unit <- probe("weak edit, verify failed",  Ans{P.Chosen{"apply_edit", 0.3},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, True{}, False{}, None{})
    ug : Unit <- probe("weak search, verify failed",Ans{P.Chosen{"search_code", 0.3},     P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, True{}, False{}, None{})
    uh : Unit <- probe("weak edit, read landed",    Ans{P.Chosen{"apply_edit", 0.5},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, True{}, None{})
    ui : Unit <- probe("weak search, read landed",  Ans{P.Chosen{"search_code", 0.3},     P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, True{}, None{})
    uj : Unit <- probe("done, plan open",           Ans{P.Chosen{"task_complete", 0.9},   P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, Some{"edit tools_c.h"})
    uk : Unit <- probe("edit, plan open",           Ans{P.Chosen{"apply_edit", 0.9},      P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.9}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, Some{"edit tools_c.h"})
    ul : Unit <- probe("done, plan clear",          Ans{P.Chosen{"task_complete", 0.9},   P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}}, False{}, False{}, False{}, False{}, False{}, False{}, None{})
    u16 : Unit <- IO.print("page options -> " ++ List.show(~&2, ~P.OptionPair, ~show_opt, page_options("3\tthree\n7\tseven\nno tab here\n12\ttwelve")))
    u17 : Unit <- IO.print("window options -> " ++ List.show(~&2, ~P.OptionPair, ~show_opt, window_options(560n, 200n)))
    u18 : Unit <- IO.print("read options -> " ++ List.show(~&2, ~P.OptionPair, ~show_opt, read_options("tools_c.h\nREADME.md\ndocs\n", ["tools_c.h"])))
    u19 : Unit <- aprobe("confident anchor, present", anchor_route(P.Chosen{"7", 0.9}, P.Nouled{0.95}))
    u20 : Unit <- aprobe("confident anchor, absent",  anchor_route(P.Chosen{"7", 0.9}, P.Nouled{0.1}))
    u21 : Unit <- aprobe("low-confidence anchor",     anchor_route(P.Chosen{"7", 0.3}, P.Nouled{0.95}))
    u22 : Unit <- aprobe("unparsable anchor",         anchor_route(P.Chosen{"bogus", 0.9}, P.Nouled{0.95}))
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
#|edit, nothing read -> reread
#|answer, nothing read -> reread
#|edit, read done -> act(apply_edit)
#|search, misses high -> reread
#|search, first miss -> act(search_code)
#|weak edit, floor spent -> act(apply_edit)
#|weak done, floor spent -> reread
#|weak read, floor spent -> act(read_code)
#|read, reads out -> skip
#|edit, reads out -> act(apply_edit)
#|weak edit, verify failed -> act(apply_edit)
#|weak search, verify failed -> reread
#|weak edit, read landed -> act(apply_edit)
#|weak search, read landed -> reread
#|done, plan open -> reread
#|edit, plan open -> act(apply_edit)
#|done, plan clear -> act(task_complete)
#|page options -> [3 => three, 7 => seven, 12 => twelve]
#|window options -> [1 => lines 1 to 200, 201 => lines 201 to 400, 401 => lines 401 to 560, none => The code to change is not in any of these ranges]
#|read options -> [README.md => README.md, docs => docs, none => No listed file is worth reading for this goal]
#|confident anchor, present -> anchor(7)
#|confident anchor, absent -> back(the file does not contain the code the change needs)
#|low-confidence anchor -> back(the anchor Choice was not confident enough to trust)
#|unparsable anchor -> back(the anchor Choice named no line of the file)
#|missing anchor -> back(Classify returned no anchor: rate limited)
