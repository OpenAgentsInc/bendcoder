# Are we using Jev properly?

An audit of Bendcoder's `Classify` against TypeSafe's design rules and measured
cookbooks, as recorded in `~/coder/docs/jev/`. Verified against a live call to
`api.typesafe.ai/v1/systemone` on 2026-09-18.

**Short answer: no.** Bendcoder uses Jev as a four-question router over a string
blob. Jev is a next-step selector that can make the agent's dominant failure
modes structurally impossible, and three of them are things this repository has
already filed issues about.

---

## What Jev actually is

A System One model. It evaluates **one state** against a **map of typed
questions** and returns **one typed answer per question, with probabilities**,
in about 100 ms. It generates no text.

| Type | Asks | Answer |
| --- | --- | --- |
| Choice | Which one of these named options? | `choice`, `probabilities`, `confidence` |
| Score | Which level on this ordered rubric? | `score`, `legend`, `probabilities`, `confidence` |
| Noul | Is this true? | `noul`, a probability from 0 to 1 |

Three properties drive everything below:

1. **Every question sees the same state and is evaluated independently, in
   parallel.** Adding a question costs its own tokens and almost no latency.
   TypeSafe measured batching thirteen questions at **12.2× cheaper and 10.0×
   faster** than asking them one at a time, with no change in answers. Bendcoder
   asks four. It should ask a dozen.
2. **Choice probabilities always sum to one.** The model *must* pick one of the
   options given. A Choice with no escape hatch cannot say "none of these fit".
3. **It cannot generate text, so it cannot fabricate.** Anywhere Bendcoder asks a
   generative model to *reproduce* something that already exists, Jev can
   *select* it instead, and the failure mode disappears rather than being
   recovered from.

## What Bendcoder sends today

```json
{ "model": "jev-latest",
  "state": "<one concatenated string of [label]: sections>",
  "questions": {
    "action":            { "type": "choice", "criteria": { 6 options, no escape } },
    "has_enough_info":   { "type": "noul" },
    "needs_code_change": { "type": "noul" },
    "confidence_score":  { "type": "score", "criteria": [ 3 levels ] } } }
```

---

## The findings

### 1. The `action` Choice has no no-match outcome — and this explains the loops

Design rule 5: *include a no-match outcome; Choice probabilities always sum to
one, so a ranking alone cannot say that nothing fits.*

`action` offers six options and no `none`. Jev is therefore **required** to
name an action on every step, however poorly any of them fit. That is the
mechanism behind the two worst behaviours observed:

- Delegating #10, `apply_edit` was chosen **eight times** and failed every time.
- Testing search, `search_code` was chosen **six times running** and missed
  every time.

Neither was Jev being wrong. It was answering the only question it was asked:
*of these six, which is best?* Nothing let it say *none of these; the state does
not support an action right now.* Issues #9 and #24 both describe the symptom;
this is the cause.

### 2. A Choice over line ids removes fabrication instead of recovering from it

The single most valuable finding.

The line-by-line search cookbook: *tag each line with an id, one Choice over
all line ids ranks them, one Noul says whether the document answers at all.*
Measured on GitHub's terms of service — 218 lines, one request, present answers
at or above 0.9 and absent ones at or below 0.05.

`tool_read` **already** emits `N<tab>line`. Those line numbers are exactly the
ids that cookbook wants.

Today Bendcoder asks a generative model to reproduce a file's bytes verbatim as
`old_string`. It cannot reliably do that: #23 records it inventing
`// close pipe and ignore exit status` and `return output;` against a file
containing neither, four times running. The fixes in 7ae0272 — refuse a blind
edit, hint at the nearest text — make that *recoverable*. Selecting a line id
makes it *impossible*: Jev picks the anchor, and **code** takes the exact bytes
from the file it just read. A model that cannot emit text cannot emit wrong
text.

The generative model still writes the replacement, which is genuinely new text.
It just stops being asked to transcribe.

### 3. The file picker should be a Choice, not generated text

The function-calling cookbook: *map function names and closed-set arguments to
Choice questions.* Design rule: free text goes to the generation model;
everything closed-set is a Choice.

Which file to read next is a **closed set** — the repository listing. Bendcoder
instead asks an LLM for a path and then mines the reply for one, because the
model prepends its reasoning:

> `Reading 'We need to view test_tools.c. We need to request the file content...test_tools.c'`

`extract_existing_path` exists solely to cope with that, and is tested with six
checks. A Choice over the paths deletes the problem and the function.

### 4. The state should be a structured object, not a string blob

Design rule 3: *send only the relevant state, structured. Prefer a JSON object
with named fields. Point a question at a field with a backticked path.*

Bendcoder concatenates everything into one string with `[label]:` headers, and
hand-escapes it into JSON in three places. Jev accepts an object. The selector
design's shape:

```json
{ "directive": "...", "program": { "step": "locate", "steps_done": [] },
  "observations": [ "bounded, newest last" ],
  "facts": { "changed_paths": [], "gate": "unknown" },
  "index": { "paths": [], "symbols": [] },
  "budget": { "turns_left": 40 } }
```

This is #14's typed transcript seen from the other end: the reason to hold the
transcript as a `List<Step>` is not only that a `char[32768]` goes deaf, it is
that a structured state is what Jev is designed to read.

The `index` field matters on its own. *Retrieval the model must ask for is not
called — inject it.* Coder measured host-injected context beating
model-requested retrieval by about 18 points. Bendcoder has `tool_grep` and a
repository listing and makes the model ask.

### 5. Four questions where a dozen cost almost nothing

Speculative fan-out is free. Questions worth adding, each of which replaces
something currently hand-coded or missing:

| Question | Type | Replaces |
| --- | --- | --- |
| `repeats` | Noul | Nothing — this is the missing fix for #9 and #24. *Would the next action repeat something already in the state?* |
| `step_done` | Noul | The `read_phase` counter |
| `blocked` | Noul | Nothing; the loop cannot currently ask for help |
| `risk` | Score | Nothing; `apply_edit` has no danger gate |
| `fits::<id>` | Noul per candidate | The skill-suggestion rerank, for when `action` confidence is low |

The skill-suggestion cookbook is the pattern for the last one: rank with one
Choice, then reread the top three with full text and allow rejecting all.
Measured wrong loads down from 16.8% to 7.3% over 488 turns.

### 6. Answers are read positionally, and one is never read at all

`extract_number(c_resp, "\"noul\":")` does a `strstr` for the **first**
occurrence. With two Nouls in the request, it always returns
`has_enough_info` and `needs_code_change` is never read — a question asked,
paid for, and discarded. The same applies to `"confidence":` and `"score":`,
which today happen to land on the right answer only because the response
preserves request order.

Verified live:

```json
{"model":"jev-1.13.0","answers":{
  "action":{"choice":"run_build","confidence":0.67,"probabilities":{...}},
  "has_enough_info":{"noul":0.1},
  "confidence_score":{"score":0.45,"confidence":0.33,...}}}
```

Also note `jev-latest` resolved to **`jev-1.13.0`**. The cookbooks pin an exact
version; a floating alias means a model upgrade silently changes every
threshold that was tuned against it.

### 7. Thresholds are scattered magic numbers

Design rules 7 and 8: *route on probability and confidence with thresholds
tuned on your own labeled data, and keep questions and thresholds in one
reviewable place.*

Bendcoder's live thresholds are `noul < 0.60` in one guardrail and
`step >= max_steps - 1` in another, inline in the dispatch. Nothing records why
0.60. Nothing was measured.

The rule also says *different actions deserve different thresholds by
consequence*. `apply_edit` writes to disk; `read_code` does not. They currently
share one path and no gate.

### 8. No retry on 429 or 529

The contract defines `429` (rate limited) and `529` (overloaded) as retryable
and returns `retry-after-ms`. Bendcoder's `curl` has no retry and no backoff; a
429 becomes an empty answer, and `extract_choice` returns `""`, which falls
through the dispatch chain to `generate_answer`. A rate limit currently
presents as a confident decision to generate.

---

## What this means for the Bend-first plan

Most of the above lands on the Bend side, and pleasingly so:

- `agent_primitives.bend` already has `Question`, `OptionPair`, `NoulQ`,
  `ChoiceQ` and `ScoreQ` types and builds the payload from them. That is
  already the "one reviewable module" rule 8 asks for. `bendcoder_agent.c` builds
  the same JSON by hand with `fputs` and a second escaper. **The question set
  belongs in Bend, once.**
- A Choice over line ids or over paths is a `ChoiceQ` whose options come from a
  `List<String>` — ordinary Bend.
- The answers deserve a type: `type Answer is Data: Chosen{...} | Scored{...} |
  Nouled{...}`, parsed once, so no caller does a positional `strstr`.
- The thresholds-to-action table is a `match` over typed answers, which is
  exactly where Bend's exhaustiveness pays.

The ordering that follows: get the answers typed and the state structured
first, because every other improvement reads them.
