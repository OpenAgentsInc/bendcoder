# Self-delegation: what works, what does not, and the workflow

How Bendcoder improves itself: a human writes (or the agent drafts) a GitHub
issue, `delegate.sh` hands the issue text to the agent as its goal with a
step budget, the agent works in a clean checkout, every edit it lands must
pass `./run_tests.sh` or it is rolled back, and the human reviews the diff
before committing. This file records what that loop has proven it can do,
the failures it exposed, and the boundary it has not yet crossed.

## The workflow

```bash
set -a && . ~/work/.secrets/typesafe.env && . ~/work/.secrets/openrouter.env && set +a
./delegate.sh <issue> <steps>     # clean tree required; logs to /tmp
./run_tests.sh                    # the human's own gate before committing
git log -p -1                     # review the diff, not just the suite result
```

Rules that keep it honest:

- The tree must be clean before delegating, so the agent's work is the diff.
- `./run_tests.sh` is the only verdict. A "pass" over a file no check
  reaches is not a pass — the coverage gate at the end of the suite fails
  any `.bend`/`.c`/`.h` absent from the `COVERED:` manifest, which is how a
  hollow `terms.bend` stub once "passed" while implementing nothing.
- The human reviews the diff. Verification catches broken code, not
  mis-styled or hollow code — one delegated run landed a correct-but-mangled
  C block that a human reindented before committing.
- Report on the issue: what ran, what failed, what changed in the loop as a
  result. The issue comments are the experiment log.

## What landed autonomously

- **#38 `store:false`** — one-line JSON body change in `openrouter_c.c`.
- **#39 TypeSafe retry parity** — a focused C change to `typesafe_c.c`
  (all 5xx + 408/429 retried, jitter, retry-count header).

Both are C edits of a few dozen lines against an existing structure — the
shape the loop handles reliably.

## Failures the delegation runs exposed, and the fixes

Each of these was found by watching a delegation fail, not by review:

| Failure | Fix |
| --- | --- |
| Under-floor `apply_edit` rerouted forever with no tally | The confidence floor "buys information": two consecutive under-floor reroutes spend it, and the third under-floor decision acts through its guarded path (`reads.bend` `floor_reads`/`book_spent`, `selector.bend` `spent` scrutinee) |
| Model-drafted `old_string` uniformly indented → exact match refused | `tool_edit` dedents `old_string`/`new_string` by their common leading whitespace and retries (`tools_c.h`) |
| Read picker declined every file → `read_code` rerouted into the same dead pick 14 times | `Book.skips` tracks consecutive declined picks; `book_read_out` removes `read_code` from the action Choice entirely once reads are exhausted, and the route falls back to search |
| `apply_edit` could not create files | `apply_block` branches on `existed`: new path → `WriteFile`, existing → `EditFile`; rollback already knew how to remove a created file |
| A created `.bend` stub passed the suite untouched | The coverage-complement gate in `run_tests.sh` (any non-ignored source absent from `COVERED:` fails) |
| Model pattern-matched the issue's Rust references and drafted `env::var` | Generation prompts now state the repo is Bend2 + C; issue text names the target files explicitly |
| `==`/`&&`/`||`/`String.equals` in every Bend draft | README's Bend Constraints names the trap; the same constraint rides in the draft prompts |
| Weak `apply_edit` after a failed verify rerouted instead of retrying | `S.answer_retry_edit`: a failed `facts.verification` lets an under-floor `apply_edit` act on the error already in the state, and it does not count as a flail-reroute |
| A draft pasted a numbered diff hunk into a heredoc; the `87\t`-prefixed terminator never matched, `cat` swallowed the rest of `run_tests.sh` into the prelude, and the script exited 0 having verified almost nothing | The `SUITEPASS` trap: the suite sets the flag only at its final line, so any earlier exit — a swallowed script, a truncation, a stray `exit 0` — fails loudly instead of self-certifying; and `tool_edit` refusing a `new_string` of `N<tab>`/`N.N<tab>`-prefixed lines as a numbered diff hunk, so the paste itself is caught at the tool rather than by the gate it corrupts |

Plus two knobs that make experiments cheap: `BENDCODER_MODEL` overrides the
generation model per run, and `BENDCODER_MAX_STEPS` sets the budget.

## The boundary: module-scale pure-Bend authoring

Issue #40 (the goal-term sniff) needed a new ~100-line recursive pure-Bend
module. Roughly eight delegation runs — on both `gpt-oss-120b` and
`claude-sonnet-4.5` — failed to land it. The loop mechanics worked
throughout (draft → create → verify → rollback → retry on the compile
error), and every draft died on a different Bend2 rule:

1. Rust hallucination → fixed by anchoring prompts/issue text.
2. C-style infix (`==`, `&&`, `||`) → fixed by naming the constraint.
3. `match` on a computed value (the scrutinee must be a parameter/field).
4. A 112-word stop list emitted as an unbalanced `Bool.or` tree (the
   idiom is data: `List.contains(~String, ~String.eq, stops, w)`).
5. Invented APIs: `Char.code`, `String.equals`, `String.to_lower` (which
   exists in base but outside the agent's grep range), `65u` literals.
6. `Cons` for `Con`; `match` on a local binder, not just on calls.

Each hint in the issue text fixed exactly one wall and revealed the next;
the model's final *plan* described every constraint correctly and still
could not emit the code. The implementation was landed manually (`96d39b7`).

**Hypotheses for closing the gap**, in rough order of leverage:

- **Seed a base-API digest into the state.** Half the failed drafts were
  API-name guesses; the agent's grep cannot see `base.bend`. The sniff
  (#40) now makes seeding arbitrary retrieval before step 1 cheap.
- **A Bend2 syntax exemplar in the draft prompt** — one small correct
  recursive module is worth more than a list of prohibitions.
- **Keep delegated tasks small.** The model succeeds at C edits and
  single-function Bend edits; "new module" is the failure shape, so issues
  should be sized to the demonstrated envelope until it grows.

## The second boundary: wide mechanical threading

Issue #41 (token usage into `budget`) was not a novel-authoring problem —
it was ~10 mechanical touch points across 4 files (a new FFI extractor, a
field on both `State` and `Report`, every pattern match, the render, the
suite prelude). At 20 steps the one draft was correctly refused (edit to an
unread file) and Jev never re-proposed; at 40 it landed one hunk of ten and
corrupted the suite itself in the process — the numbered-heredoc paste the
`SUITEPASS` trap now guards against. Field-threading is the kind of change
a human calls tedious; at ~5-8 steps per propose→anchor→read→draft→verify
cycle it does not fit a 40-step budget either. Two distinct walls, then:

1. **Novel recursive pure-Bend modules** — outside the generation model's
   current ability at any budget tried (#40).
2. **Multi-file field-threading** — within its ability per-hunk, outside
   the fuel budget a delegation reasonably gets (#41).

What remains squarely inside the envelope: single-file C edits, focused
single-site Bend changes, and every loop-hardening fix this document
records — those all landed or were drafted by the agent itself.

## What landed where

- `#38`, `#39` — delegated, applied and verified by the agent (`612e58f`,
  `e169b8e`).
- `#40`, `#41` — implemented manually after the boundaries above were
  mapped (`96d39b7`, `7fb8e24`); the loop fixes each delegation exposed
  are the agent's real yield from those runs.

`docs/roadmap.md` carries the follow-on assessment — why these are the
boundaries, what the limiting factors actually are, and the ordered
upgrade path tracked as issues #42–#48.
