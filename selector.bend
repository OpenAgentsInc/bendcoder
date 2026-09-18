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
    probe("missing",                                Ans{P.Missing{"rate limited"},        P.Nouled{0.1}, P.Nouled{0.1}, P.Nouled{0.1}, P.Scored{0.2, 0.8}, P.Scored{0.1, 0.9}})

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
