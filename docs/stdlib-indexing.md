# Indexing the standard library: what #48 actually needs

An assessment of [#48](https://github.com/OpenAgentsInc/bendcoder/issues/48),
which proposes semantic/AST indexing of Bend's standard library by one of two
routes — a `tree-sitter-bend` grammar, or a Bend-written indexer — and defers
the choice until "the model stops guessing names and starts reasoning about
types".

**The recommendation is neither, yet.** Measured against what `base_api.bend`
already produces, the queries the issue names are answerable from signature
text, and the parse tree buys nothing until the questions move from signatures
into bodies. The cheap version should be built and measured first, because it
is the only thing that can tell you whether either project is worth starting.

---

## What exists after #44

`base_api.bend` reads `base.bend` and emits its top-level `def`/`type`/`law`
signature lines, joining indented continuations and keeping ten namespaces.
Run against the real standard library today:

```
signatures kept: 223
type Bool is Data:
type Nat is Data:
```

That is 223 of the 467 top-level declarations in `base.bend`'s 2,827 lines,
filtered to the surface this repository's own Bend actually calls. The lines
are whole signatures, **return types included** — `def String.to_lower(s:
String) -> String:`, not just the name.

The joining matters more than it looks: 131 of those declarations span more
than one line, so a naive `grep '^def '` would truncate almost a third of the
surface mid-type and hand the model a lie.

## The issue's own examples do not need a parse tree

#48 names three richer queries. Each is a filter over the text already in the
digest:

| Query | Answered by | Count today |
| --- | --- | --- |
| "defs returning `Bool`" | signature ends `-> Bool:` | 40 in the kept namespaces |
| "functions taking `String -> Bool`" | a `-> Bool` inside the parameter list | 5 |
| "constructors of `List`" | the `type List ... is Data:` block and its arms | 1 block |

A `def` line states its return type and its parameter types. Knowing that
`String.eq(a: String, b: String) -> Bool` returns a `Bool` requires reading the
signature, not parsing it. The shape query the issue frames as needing
"parse-level queries" is a substring match away from working.

What a parse tree genuinely buys is questions about **bodies**: which functions
call `List.foldr`, which are self-recursive, which match on a particular
constructor. #48's stated motivation — the model inventing `String.equals` when
`String.to_lower` exists — is a *name and signature* problem, and it is the one
already addressed.

## What to build instead, and what it would prove

One narrow addition: a typed filter over the digest, so `index.base_api` can be
asked for the signatures matching a shape rather than always carrying the same
prefix of the list.

That is a day's work in `base_api.bend`, it is pure, it can carry laws the way
`tool_read.bend` does, and it produces the number that decides #48: **how often
does the loop still guess a name or a type after being handed the matching
signatures?** If that number is near zero, neither indexing project is worth
starting. If drafts keep failing on things a signature cannot express — calling
a function that exists with arguments in the wrong order, or missing that a
value is `Type`-kinded and cannot be copied — then the case for a parse tree is
made with evidence rather than anticipated.

## If the decision does come, the two paths are not equal

Recorded now so the comparison does not have to be redone:

**tree-sitter-bend** is a real grammar plus a query layer plus an FFI surface.
It is also a C dependency vendored into a repository whose premise is that
everything expressible in Bend belongs in Bend, and a second grammar that must
track Bend 2.x as it moves — this session alone hit `+x` quantities, `&2`
kinds, multi-scrutinee `match`, `law`/`def` pairing and `#|` expectations, all
of which the grammar would have to know. When it drifts, it drifts silently:
a grammar that mis-parses returns wrong answers rather than failing.

**A Bend-written indexer** is slower to start and has the obvious bootstrap
smell, but it is checked by the same compiler as everything else, it can state
laws about its own output, and it cannot drift from the language without
failing to build. `base_api.bend` is already a small one — 149 lines of pure
Bend doing line-level extraction with no dependency at all. The honest question
is not "which is better" but "how much further does that file have to go before
it answers the questions being asked", and the filter above is how you find out.

There is a third possibility worth naming: `bend` itself already parses Bend,
and a flag that emitted a machine-readable declaration list would make both
projects unnecessary. That is a question for the language, not this repository,
but it is cheaper than either path here and should be asked first.

## Recommendation

Close #48 as the horizon marker it is, with this assessment attached, and open
the narrow filter as its own issue when the loop's failures justify it. The
trigger to reopen is specific: a run where the draft had the right signature in
`index.base_api` and still got the call wrong.
