#!/usr/bin/env bash
# Verification target for the self-improvement loop: the file tools, the agent's
# own helpers, the FFI shims, the scripts, the markdown, and that the Bend
# programs still check and build.
#
# The suite is the only thing standing between the loop and a bad self-edit, so
# two properties matter as much as the checks themselves: warnings are errors,
# because a warning the suite prints and ignores is a check that does not exist
# (#8, #22), and the suite reports what it covered, because a green run over a
# file no check reads is not a verification (#22).
#
# Every artefact goes in a per-run temp directory, so several checkouts can run
# this at once — which is what delegating a batch of issues to parallel agents
# in separate worktrees does.
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bendcoder_tests_XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export BENDCODER_TEST_DIR="$WORK/scratch"

echo "== tools and agent helpers =="
gcc -std=c11 -O1 -Wall -Wextra -Werror -I. test_tools.c -o "$WORK/test_tools"
"$WORK/test_tools"

# The FFI shims compile only inside generated Bend programs — where -Werror
# cannot go, because generated code is not warning-clean — and then only the
# sections a program reaches from main: nothing in the tree reaches
# CID_SYS_READ_FILE, CID_SYS_WRITE_FILE or CID_SYS_EDIT_FILE, so those sections
# had never been compiled by anything at all. Checking each shim standalone
# against a prelude declaring the runtime's side of the boundary compiles every
# section at the same -Werror standard as the agent's own C. The prelude
# mirrors declarations from the generated runtime (see bendcoder_loop.c); if
# Bend's runtime ABI shifts this fails loudly, which is the check working.
echo
echo "== FFI shims compile, all sections =="
cat > "$WORK/ffi_prelude.h" <<'PRELUDE'
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef float    f32;
typedef u64      Term;
typedef struct { void* mem; u64* alc; } Env;

typedef struct IoWork IoWork;
typedef void (*IoCall)(IoWork* w);
typedef Term (*IoPack)(Env e, IoWork* w);
struct IoWork {
  intptr_t hand; intptr_t made; u32 word; u64 size;
  char*    data; char*    text; u32 code;
  IoCall   call; IoPack   pack;
};
typedef Term (*Effect)(Env e, Term* f, IoWork* w);

char* io_cstr(Env e, Term s, u64* len);
Term  io_str(Env e, const char* p, u64 n);
Term  io_work(IoWork* w, IoCall call, IoPack pack);
Term  io_done(Env e, Term v);
Term  io_fail(Env e, u32 code, const char* text);
Term  io_box(Env e, u64 cid, Term v, int hot);
Term  io_node(Env e, u64 cid, Term a, Term b, int hot);
Term  term_pak(u64 cid, u64 loc);
u64   f32_rewrap(f32 x);
void  io_eff(u32 cid, Effect run, u32 need);

#define CID_COMMAND_RUN        1
#define CID_SYS_READ_FILE      2
#define CID_SYS_READ_RAW       3
#define CID_SYS_WRITE_FILE     4
#define CID_SYS_EDIT_FILE      5
#define CID_SYS_GREP_FILE      6
#define CID_TYPESAFE_POST      7
#define CID_OPENROUTER_POST    8
#define CID_EXTRACT_ANSWER     9
#define CID_EXTRACT_GENERATION 10
#define CID_MISSING 11
#define CID_CHOSEN  12
#define CID_SCORED  13
#define CID_NOULED  14
#define CID_SYS_EXISTS      15
#define CID_SYS_REMOVE_FILE 16
PRELUDE
for f in sys_c.c json_parse_c.c typesafe_c.c openrouter_c.c; do
  gcc -std=c11 -O1 -Wall -Wextra -Werror -c -I. \
    -include "$WORK/ffi_prelude.h" "$f" -o "$WORK/$f.o" || { echo "FAIL: $f"; exit 1; }
  echo "PASS: $f"
done

echo
echo "== shell scripts parse =="
for f in *.sh; do
  bash -n "$f" || { echo "FAIL: $f"; exit 1; }
  echo "PASS: $f"
done

# A .bend file's expected stdout lives in the file as `#|` lines — the same
# convention Bend's own gate uses (~/bend/gates/test.ts) — so a change and its
# test fit one hunk in one file, which is the shape the loop's apply_edit can
# produce. Files without `#|` lines are skipped.
echo
echo "== bend expected output (#|) =="
for f in *.bend; do
  grep -q '^#|' "$f" || continue
  want="$(grep '^#|' "$f" | sed 's/^#|//')"
  # Compiled, not interpreted. A file importing the C FFI cannot run directly --
  # "a foreign def without a .js import" -- and those are exactly the files
  # worth testing. Compiling is also how these programs actually run.
  bend "$f" -o "$WORK/$f.c" >/dev/null 2>"$WORK/$f.err" \
    && gcc -std=c11 -O1 -I. "$WORK/$f.c" -lpthread -lm -o "$WORK/$f.bin" 2>>"$WORK/$f.err" \
    || { echo "FAIL (build): $f"; cat "$WORK/$f.err"; exit 1; }
  got="$("$WORK/$f.bin" 2>>"$WORK/$f.err")" || { echo "FAIL (run): $f"; cat "$WORK/$f.err"; exit 1; }
  [ "$got" = "$want" ] || { echo "FAIL: $f"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") || true; exit 1; }
  echo "PASS: $f"
done

# The action space's parse/show round-trip is a proved law; checking the
# module is what makes it a gate rather than a comment.
echo "== action.bend proves its laws =="
bend action.bend >/dev/null

# The path guard is proved rather than exemplified: LAWS.bend states the
# refusal rules over every input and PROOF.bend fills each one, so an
# unproved law fails here the way a failing test does.
echo "== PROOF.bend proves the path guard =="
bend PROOF.bend >/dev/null

# tool_read.bend carries its own laws -- the paging arithmetic and the
# line-number round-trip Edit's fallback depends on. Checking the module is
# what makes them a gate rather than a comment.
echo "== tool_read.bend proves its laws =="
bend tool_read.bend >/dev/null

# bendcoder_agent.bend uses only some of the laws sys_c.c defines, so this also
# guards the #ifdef CID_* guards in sys_c.c against regressing (issue #5).
echo "== bendcoder_agent.bend checks and builds =="
bend bendcoder_agent.bend -o "$WORK/bendcoder_loop.c" >/dev/null
gcc -std=c11 -O1 -I. "$WORK/bendcoder_loop.c" -lpthread -lm -o "$WORK/bendcoder_loop_bin"

# call_typesafe.bend has no #| expectations — running it needs a live API key —
# but it is still a program the repo ships, so the suite compiles it.
echo "== call_typesafe.bend checks and builds =="
bend call_typesafe.bend -o "$WORK/call_typesafe.c" >/dev/null
gcc -std=c11 -O1 -I. "$WORK/call_typesafe.c" -lpthread -lm -o "$WORK/call_typesafe_bin"

# Prose gets a floor too (#22): an edit that breaks a document's structure used
# to pass the suite untouched. Three structural rules — every fenced block
# closes; a fence may not hang directly off a list item, where it reads as part
# of a list it actually ends; and a section break may not be inserted between a
# line ending in ":" and the block it introduces, the shape that orphaned an
# example in #21.
echo
echo "== markdown structure =="
for f in *.md docs/*.md; do
  [ -f "$f" ] || continue
  awk '
    /^```/ {
      if (!in_fence) {
        if (prev_list) {
          printf "%s:%d: fenced block directly follows a list item, so it reads as part of a list it actually ends\n", FILENAME, NR
          bad = 1
        }
        pending_intro = 0
      }
      in_fence = !in_fence
      next
    }
    in_fence { next }
    /^[[:space:]]*$/ { next }
    {
      if (pending_intro &&
          ($0 ~ /^#+ / || $0 ~ /^#+$/ || $0 ~ /^---/ || $0 ~ /^\*\*\*/ || $0 ~ /^___/)) {
        printf "%s:%d: a section break splits a line ending in \":\" (line %d) from the block it introduces\n",
               FILENAME, NR, intro_line
        bad = 1
      }
      pending_intro = 0
      prev_list = 0
      if ($0 ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/) {
        prev_list = 1
      } else if ($0 ~ /:[[:space:]]*$/ &&
                 $0 !~ /^[[:space:]]*#/ &&
                 $0 !~ /^[[:space:]]*>/ &&
                 $0 !~ /^[[:space:]]*\|/) {
        pending_intro = 1
        intro_line = NR
      }
    }
    END {
      if (in_fence) { printf "%s: unclosed fenced code block\n", FILENAME; bad = 1 }
      if (pending_intro) {
        printf "%s:%d: line ends in \":\" but introduces nothing\n", FILENAME, intro_line
        bad = 1
      }
      exit bad
    }
  ' "$f" || exit 1
  echo "PASS: $f"
done

# What a pass actually covers: the files a check above reads — this script, the
# compiled C, the scripts and markdown checked wholesale, the Bend programs run
# or built — plus everything reached through repo-local references (a Bend
# import, a quoted C include), so a file pulled in indirectly counts too.
# apply_edit reads the COVERED lines back out of this output and reports a pass
# over a file absent from them as the weaker thing it is (#22). The seeds are
# enumerated, not globbed, so a file no check reads never slips into the
# manifest by accident.
echo
echo "== suite coverage =="
local_refs() {
  { grep -oE 'import[[:space:]]+"?\./[^"[:space:]]+' "$1" \
      | sed -E 's/^import[[:space:]]+"?\.\///'
    grep -oE '#include[[:space:]]+"[^"]+"' "$1" \
      | sed -E 's/^#include[[:space:]]+"//; s/"$//'
  } 2>/dev/null
}
SEEN="$WORK/covered.txt"; : > "$SEEN"
queue="run_tests.sh test_tools.c sys_c.c"
queue="$queue $(grep -l '^#|' *.bend 2>/dev/null)"
queue="$queue action.bend bendcoder_agent.bend call_typesafe.bend PROOF.bend tool_read.bend"
queue="$queue *.sh *.md docs/*.md"
while [ -n "$queue" ]; do
  next=""
  for f in $queue; do
    grep -qxF "$f" "$SEEN" && continue
    [ -f "$f" ] || continue
    printf '%s\n' "$f" >> "$SEEN"
    next="$next $(local_refs "$f")"
  done
  queue="$next"
done
sort -u "$SEEN" | sed 's/^/COVERED: /'

echo
echo "All checks passed."
