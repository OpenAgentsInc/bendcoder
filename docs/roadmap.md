# The self-improvement roadmap

`docs/self-delegation.md` records what the delegation runs proved and the
two boundaries they mapped. This file is the assessment that follows from
it: why those are the boundaries, what the real limiting factors are, how
to make the standard library visible, and the ordered upgrade path —
tracked as issues #42–#48.

## Where the loop stands

Verified autonomous envelope, demonstrated on live delegations:

- Single-file C edits (#38 `store:false`, #39 TypeSafe retry parity).
- Focused single-site changes and every loop-hardening fix the delegation
  failures exposed.
- The full pipeline: read → search → plan → anchor/sentinel edit →
  `WriteFile` for new files → `./run_tests.sh` verify → keep → repair the
  failed draft in place on the error already in the state → the goal-term
  sniff seeding deterministic retrieval before step 1.

Outside the envelope today:

- Novel recursive pure-Bend module authoring (#40, landed manually).
- Multi-file mechanical field-threading (#41, landed manually).

## Why those are the boundaries — the shared root

The two walls look different but share one cause: **the loop samples, it
does not converge.** The state records what happened — observations, search
hits, verification results — but nothing records what is left to do or
what was almost right. Every action is effectively a fresh sample rather
than a delta on prior work.

- For novel modules: a failed draft is rolled back and re-drafted from
  scratch. The compile error lands in the state, but the near-miss file is
  deleted, so each new draft must satisfy every constraint simultaneously
  again — scrutinee rules, `Con` not `Cons`, real APIs only, no infix.
  The joint probability of a clean ~100-line draft is low and does not
  improve across attempts. Sonnet's final plan described every rule
  correctly and still could not emit it — a generation-fidelity problem,
  not a comprehension problem. A human converges error-by-error on a
  file that stays on disk; the loop rolls the dice again.
- For field-threading: `apply_edit` lands one hunk per cycle by design,
  and nothing in the state says "you are 3 of 10 hunks through a plan."
  Between hunks the model re-orients — re-searching names it already has —
  because the issue text is the only plan and it is static. ~6–8 steps per
  hunk plus re-orientation means a ~10-site change cannot fit any
  reasonable budget.

Same gap, two symptoms: one-shot correctness is impossible for
unfamiliar-language module-scale code, and one-hunk-per-cycle is too slow
for multi-site edits.

## The aggravators

In rough order of how much they amplified the two walls above.

1. **No repair primitive.** The largest single factor — covered by #42.
2. **The standard library is invisible.** `act_search_code` hardcodes
   `P.Grep(pattern, ".")`; base.bend lives outside the repo. Half the
   failed #40 drafts were API guesses against a library the model cannot
   see — it searched for `String.to_lower`, found nothing in this repo,
   and concluded it does not exist. It does. Covered by #44.
3. **Verify granularity.** Every draft pays the whole suite — a minute or
   more plus several steps — even when the failure is a plain typecheck.
   At a 40-step budget that is roughly five draft attempts, and nothing
   converges in five samples. Covered by #43.
4. **No sub-goal persistence.** After a refused edit named a file and the
   read landed, nothing marked "re-draft that edit now" — Jev wandered
   back to searching. There is no worklist, so orientation cost is paid
   per hunk. Covered by #45 and #46.
5. **Bend2 prior ≈ zero.** The model has almost no Bend2 in its weights
   and pattern-matches Haskell/OCaml/Rust (`Cons`, `==`, `String.equals`).
   Hints in the issue text are consumed as fast as they are produced —
   each fixed exactly one wall because the knowledge lives in prompts,
   not in the model. A syntax exemplar may help; this is the residual
   model ceiling the loop fixes above will expose.

## Making the standard library visible

The observed failure was never a parsing problem — it was a model asked
to write code against a library it could not observe. Any fix is right
only insofar as it makes `String.to_lower` visible *before* the draft,
not discoverable after the compile error.

**Now: a digest in the index (#44).** `run_agent` already injects
`index.paths` before step 1. The same move for base: resolve base.bend via
a `BENDCODER_BASE` env var, extract `^(def|type) ` signature lines —
Bend top-level forms are column-0 single-line signatures, so regex
extraction covers nearly all of the surface — filter to the namespaces
the agent uses, and render them in `state_to_json` like `index.paths`.
The draft prompts then see `String.to_lower(s: String) -> String` and the
invention pressure disappears. One constraint worth knowing: untracked
files are invisible to tree grep, so the digest must land in the *state*
(or be a committed file, which drifts) — a generated file dumped in the
repo is not greppable.

**Variant: a searchable second root.** Teach `search_code` a second scope
(`P.Grep` against `BENDCODER_BASE`) or add a `search_base` action. More
flexible — the model queries names lazily — but every search then has two
scopes to reason about and the hits land in an already budget-tight
state. A refinement, not the first fix.

**Later: semantic indexing (#48).** TreeSitter would buy *semantic*
queries — defs returning `Bool`, functions taking `String -> Bool`,
constructors of `List`. That is a richer capability than the observed gap,
and the cost is real: a `tree-sitter-bend` grammar has to handle `+x`
affine markers, `&2` kinds, `match`/`case`, `law`, `do` blocks and `#|`
expectations, then a query layer and an FFI surface on top. It spends the
effort on the axis — parse precision — that is not the bottleneck. The
dogfooding alternative is a Bend-written indexer: Bend parses its own
fixed grammar and emits the index, and the stdlib solution becomes
another self-hosted capability. Revisit either when the model stops
guessing names and starts reasoning about types.

## The upgrade path

Ordered by leverage. Each issue states the observed failure it fixes.

| # | Issue | Unblocks |
| --- | --- | --- |
| #42 | Repair failed drafts in place instead of resampling | The novel-module boundary — turns draft→verify→rollback→resample into draft→verify→keep→repair |
| #43 | Two-tier verification: cheap `bend` check before the suite | Makes #42's repair cycles seconds instead of minutes; more attempts per budget for everything |
| #44 | Seed the base-API digest into `index` | Deletes the API-invention failure class |
| #45 | Carry a plan/worklist in the agent state | The field-threading boundary — amortizes orientation across hunks |
| #46 | Resume a refused edit after the named read lands | Small routing gap observed live in the #41 run |
| #47 | `tool_edit`: handle numbered diff-hunk pastes in `new_string` | Hardens the paste class SUITEPASS catches the consequence of |
| #48 | Horizon: semantic/AST indexing (TreeSitter or self-hosted) | Deferred until retrieval questions go semantic |

Sequencing notes:

- #43 before or with #42 — repair without cheap checks is still slow.
- #44 is small and independent; it uses the injection machinery the sniff
  already built.
- #45 is the largest architectural piece; until it lands, keep delegated
  issues sized to the demonstrated envelope.
- Once #42–#45 land, re-delegate a #40-shaped task (a small new pure-Bend
  module) as the regression test for whether the boundary moved.

The honest summary: the boundaries are not "the model cannot" — they are
"the loop has no memory of partial progress." That is fixable, and it is
the next upgrade the system should try to give itself.
