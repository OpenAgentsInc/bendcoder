import Base

# ==============================================================================
# plan.bend: the worklist the state carries between hunks (#45)
# ==============================================================================
# The second delegation boundary: a multi-site change re-orients between hunks
# because nothing records progress — the issue text is the only plan and it is
# static (#41). The `plan` action decomposes the goal into concrete hunks once;
# the worklist then travels in State, rendered every step, and items check off
# as their named files change. This module is the item type and its pure
# helpers — the reply parser, the renderer, the marker, and the next-open
# query the selector gates a premature task_complete on.
# ------------------------------------------------------------------------------

# One hunk: the line the model wrote, and whether its named file has since
# changed. `done` is data rather than a prefix inside `text`, so a marked item
# cannot silently re-open on the next render.
type Item is Data:
  It{text: String, done: Bool}

# Whether `text` names an element of `xs` — the item's file appearing in the
# changed list (mark) or the repository listing (open). List.contains's `eq`
# sees (element, query), so the arguments arrive flipped from contains's.
def named_by(+p: String, +text: String) -> Bool:
  String.contains(text, p)

def names(+text: String, +xs: List<&2, String>) -> Bool:
  List.contains(~String, ~named_by, xs, text)

# A hunk an edit can still discharge: unchecked and naming a tracked file. An
# item naming nothing on disk is advisory text no change can mark, so it never
# gates task_complete — a worklist the loop cannot finish must not become one
# it cannot end.
def item_open(i: Item, +paths: List<&2, String>) -> Bool:
  match i:
    case It{+text, +done}:
      Bool.and(Bool.not(done), names(text, paths))

def head_open(+xs: List<&2, Item>, +paths: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      item_open(h, paths)

def item_text(+i: Item) -> String:
  match i:
    case It{+text, done}:
      text

# The hunk the loop owes next: the first unchecked item naming a tracked file —
# what the selector's gate reroutes a premature task_complete toward, and the
# text its reason names. `hit` is the head test computed by the caller, the
# same shape rd_find.go carries.
def next_open.go(+xs: List<&2, Item>, +paths: List<&2, String>, hit: Bool) -> Maybe<&2, String>:
  match xs hit:
    case Nil{} _:
      None{}
    case +h <> t True{}:
      Some{item_text(h)}
    case h <> t False{}:
      next_open.go(t, paths, head_open(t, paths))

def next_open(+plan: List<&2, Item>, +paths: List<&2, String>) -> Maybe<&2, String>:
  next_open.go(plan, paths, head_open(plan, paths))

# An item whose named file changed is done — marked in place, and a done item
# stays done.
def mark_item(i: Item, +changed: List<&2, String>) -> Item:
  match i:
    case It{+text, +done}:
      Bool.pick(Item, Bool.or(done, names(text, changed)),
        It{text, True{}}, It{text, False{}})

def mark.go(+xs: List<&2, Item>, +changed: List<&2, String>, acc: List<&2, Item>) -> List<&2, Item>:
  match xs:
    case Nil{}:
      List.reverse(&2, Item, acc)
    case +h <> t:
      mark.go(t, changed, mark_item(h, changed) <> acc)

# apply_report's half of "marks items done as their named files change": every
# item naming a path this step's report left changed checks off.
def mark(+plan: List<&2, Item>, +changed: List<&2, String>) -> List<&2, Item>:
  mark.go(plan, changed, {Nil{} : List<&2, Item>})

# ------------------------------------------------------------------------------
# The reply parser: one hunk per line, framing stripped
# ------------------------------------------------------------------------------
# The model's reply is one hunk per line; bullets, numbers and checkbox
# prefixes are framing, not text. A "[x] " prefix it writes is stripped like
# the rest — done state comes only from mark(), never from the draft.

# A bullet ("- ", "* ") or a quoted-back checkbox ("[ ] ", "[x] ", "[X] ") is
# list syntax; both drop.
def unbullet(+s: String) -> String:
  Bool.pick(String,
    Bool.or(String.starts_with(s, "- "), String.starts_with(s, "* ")),
    String.drop(s, 2n),
    Bool.pick(String, String.starts_with(s, "[ ] "),
      String.drop(s, 4n),
      Bool.pick(String,
        Bool.or(String.starts_with(s, "[x] "), String.starts_with(s, "[X] ")),
        String.drop(s, 4n),
        s)))

# "3. hunk" / "3) hunk": leading digits then a '.' or ')' are a number, not
# text. strip_line's scan shape — digits ending on neither separator are
# content and the line is kept whole.
def unnum.scan(s: String, +orig: String) -> String:
  match s:
    case SNil{}:
      orig
    case SCon{+h, +t}:
      Bool.pick(String,
        Bool.or(Char.is_eq(h, '.'), Char.is_eq(h, ')')),
        t,
        Bool.pick(String, Char.is_digit(h), unnum.scan(t, orig), orig))

def unnum(+s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      Bool.pick(String, Char.is_digit(h),
        String.trim_start(unnum.scan(t, SCon{h, t})),
        SCon{h, t})

# One reply line into hunk text: trim, strip framing, trim again, and clip so
# a runaway line cannot flood the state the plan renders into every step.
def plan_text_max() -> Nat: 240n

def plan.clean(+line: String) -> String:
  String.take(String.trim(unnum(unbullet(String.trim(line)))), plan_text_max())

def plan.item.of(+text: String, acc: List<&2, Item>, empty: Bool) -> List<&2, Item>:
  match empty:
    case True{}:
      acc
    case False{}:
      It{text, False{}} <> acc

def parse.go(+ls: List<&2, String>, acc: List<&2, Item>) -> List<&2, Item>:
  match ls:
    case Nil{}:
      List.reverse(&2, Item, acc)
    case +h <> t:
      +c = plan.clean(h)
      parse.go(t, plan.item.of(c, acc, String.is_empty(c)))

# The plan's own bound: a verbose reply cannot flood the state either.
def plan_max() -> Nat: 16n

def parse(+reply: String) -> List<&2, Item>:
  List.take(&2, Item, parse.go(String.lines(reply), {Nil{} : List<&2, Item>}), plan_max())

# ------------------------------------------------------------------------------
# The render: what state_to_json's `plan` array and state_text's [Plan] show
# ------------------------------------------------------------------------------
def show_item(+i: Item) -> String:
  match i:
    case It{+text, +done}:
      Bool.pick(String, done, "[x] ", "[ ] ") ++ text

def shows.cons(i: Item, acc: List<&2, String>) -> List<&2, String>:
  +s = show_item(i)
  s <> acc

def shows(+plan: List<&2, Item>) -> List<&2, String>:
  List.foldr(~&2, ~Item, ~List<&2, String>, ~shows.cons, plan, {Nil{} : List<&2, String>})

# ------------------------------------------------------------------------------
# The helpers, exercised
# ------------------------------------------------------------------------------
def show_next(m: Maybe<&2, String>) -> String:
  match m:
    case Some{+s}:
      s
    case None{}:
      "none"

def main() -> IO(Unit):
  do IO<Unit>:
    +p0 : List<&2, Item> = parse("1. add a field to foo.bend\n- mark it in bar.c\n\n[x] already done")
    u1 : Unit <- IO.print("parse -> " ++ String.join(shows(p0), " | "))
    +p1 : List<&2, Item> = mark(p0, ["foo.bend"])
    u2 : Unit <- IO.print("mark -> " ++ String.join(shows(p1), " | "))
    u3 : Unit <- IO.print("next -> " ++ show_next(next_open(p1, ["foo.bend", "bar.c"])))
    +p2 : List<&2, Item> = mark(p1, ["bar.c"])
    u4 : Unit <- IO.print("mark2 -> " ++ String.join(shows(p2), " | "))
    u5 : Unit <- IO.print("next2 -> " ++ show_next(next_open(p2, ["foo.bend", "bar.c"])))
    u6 : Unit <- IO.print("untracked -> " ++ show_next(next_open(p1, ["other.c"])))
    u7 : Unit <- IO.print("miss -> " ++ String.join(shows(mark(p0, ["zzz.c"])), " | "))
    IO.print("empty -> " ++ Nat.show(List.length(&2, Item, parse("\n  \n"))))

#|parse -> [ ] add a field to foo.bend | [ ] mark it in bar.c | [ ] already done
#|mark -> [x] add a field to foo.bend | [ ] mark it in bar.c | [ ] already done
#|next -> mark it in bar.c
#|mark2 -> [x] add a field to foo.bend | [x] mark it in bar.c | [ ] already done
#|next2 -> none
#|untracked -> none
#|miss -> [ ] add a field to foo.bend | [ ] mark it in bar.c | [ ] already done
#|empty -> 0
