import Base

# ==============================================================================
# Bendcoder Action Space
# ==============================================================================
# The agent's actions as a datatype rather than a string compared with
# String.eq in a chain. A match over Action is exhaustive: adding a seventh
# action and forgetting to handle it is a compile error, not a fallthrough.
# This was enum Action's twin while the loop lived in bendcoder_agent.c.
# ==============================================================================

type Action is Data:
  ReadCode{}
  SearchCode{}
  RunBuild{}
  ApplyEdit{}
  Plan{}
  GenerateAnswer{}
  TaskComplete{}

# The one place each action's Classify criterion name lives. The questions
# sent to Classify are built from show_action, so the name offered and the
# name parsed back cannot drift apart — which is exactly what the roundtrip
# law below proves.
def show_action(a: Action) -> String:
  match a:
    case ReadCode{}:        "read_code"
    case SearchCode{}:      "search_code"
    case RunBuild{}:        "run_build"
    case ApplyEdit{}:       "apply_edit"
    case Plan{}:            "plan"
    case GenerateAnswer{}:  "generate_answer"
    case TaskComplete{}:    "task_complete"

# A match scrutinizes only parameters and fields, never a computed value, so
# the String.eq results arrive as Bool parameters the way dispatch_action's
# already did.
def parse_action.of(
  is_read: Bool, is_search: Bool, is_build: Bool,
  is_edit: Bool, is_plan: Bool, is_answer: Bool, is_complete: Bool
) -> Maybe<&2, Action>:
  match is_read is_search is_build is_edit is_plan is_answer is_complete:
    case True{} _ _ _ _ _ _:  Some{ReadCode{}}
    case _ True{} _ _ _ _ _:  Some{SearchCode{}}
    case _ _ True{} _ _ _ _:  Some{RunBuild{}}
    case _ _ _ True{} _ _ _:  Some{ApplyEdit{}}
    case _ _ _ _ True{} _ _:  Some{Plan{}}
    case _ _ _ _ _ True{} _:  Some{GenerateAnswer{}}
    case _ _ _ _ _ _ True{}:  Some{TaskComplete{}}
    case _ _ _ _ _ _ _:       None{}

# Every test false means the decision named no action. Handing back None{}
# makes that a parse failure the caller must handle, not a silent fallthrough
# to generate_answer the way the String.eq chain did.
def parse_action(+s: String) -> Maybe<&2, Action>:
  parse_action.of(
    String.eq(s, "read_code"),
    String.eq(s, "search_code"),
    String.eq(s, "run_build"),
    String.eq(s, "apply_edit"),
    String.eq(s, "plan"),
    String.eq(s, "generate_answer"),
    String.eq(s, "task_complete"))

# The property that actually matters: the name sent to Classify in the
# criteria and the name parsed back out of its answer cannot drift apart.
# Proven once per constructor; both sides compute, so each case is {==}.
law Action.roundtrip:
  for a: Action
  {parse_action(show_action(a)) == Some{a} : Maybe<&2, Action>}

def Action.roundtrip(a):
  match a:
    case ReadCode{}:       {==}
    case SearchCode{}:     {==}
    case RunBuild{}:       {==}
    case ApplyEdit{}:      {==}
    case Plan{}:           {==}
    case GenerateAnswer{}: {==}
    case TaskComplete{}:   {==}
