// Exercises the agent's own helpers by including the runtime with main renamed.
#define main bender_main
#include "bender_agent.c"
#undef main

#include <assert.h>

static int fails = 0;
static void check(int cond, const char* what) {
  printf("%s %s\n", cond ? "ok  " : "FAIL", what);
  if (!cond) fails++;
}

// The scratch directory is overridable so several checkouts can run the suite
// at once without clobbering each other's files.
static char scratch[512];

// Returns a fresh allocation rather than a shared static buffer: several of
// these are held at once, and a static would leave earlier callers pointing at
// the most recent path.
static char* scratch_path(const char* leaf) {
  char buf[1024];
  snprintf(buf, sizeof(buf), "%s/%s", scratch, leaf);
  return strdup(buf);
}

int main(void) {
  const char* base = getenv("BENDER_TEST_DIR");
  snprintf(scratch, sizeof(scratch), "%s", base && base[0] ? base : "/tmp/bender_tool_test");
  char rm[600];
  snprintf(rm, sizeof(rm), "rm -rf '%s'", scratch);
  if (system(rm) != 0) { /* a missing directory is fine */ }

  const char* block =
    "<<<PATH>>>\nsrc/a.c\n<<<OLD>>>\nint x = 1;\n  int y = 2;\n<<<NEW>>>\nint x = 42;\n<<<END>>>\n";
  char* path = slice_section(block, "<<<PATH>>>", "<<<OLD>>>");
  char* oldv = slice_section(block, "<<<OLD>>>", "<<<NEW>>>");
  char* newv = slice_section(block, "<<<NEW>>>", "<<<END>>>");
  check(path && strcmp(path, "src/a.c") == 0, "slice PATH");
  check(oldv && strcmp(oldv, "int x = 1;\n  int y = 2;") == 0, "slice OLD keeps interior newline+indent");
  check(newv && strcmp(newv, "int x = 42;") == 0, "slice NEW");
  free(path); free(oldv); free(newv);

  check(slice_section("<<<PATH>>>\nx\n", "<<<PATH>>>", "<<<OLD>>>") == NULL, "missing close sentinel -> NULL");

  // Empty OLD is how a new file is requested: it must parse, not vanish.
  char* empty = slice_section("<<<OLD>>>\n<<<NEW>>>\n", "<<<OLD>>>", "<<<NEW>>>");
  check(empty && empty[0] == '\0', "empty OLD section parses as empty string");
  free(empty);

  // The picker's reply routinely carries the model's reasoning; a path must
  // still be recovered from it, and refused when there is none.
  char* p1 = extract_existing_path("tools_c.h");
  check(p1 && strcmp(p1, "tools_c.h") == 0, "bare path extracted");
  free(p1);
  char* p2 = extract_existing_path(
    "We need to view test_tools.c.We need to request the file content. So answer: test_tools.c");
  check(p2 && strcmp(p2, "test_tools.c") == 0, "path extracted from leaked reasoning");
  free(p2);
  char* p3 = extract_existing_path("Let's read `run_tests.sh` next.");
  check(p3 && strcmp(p3, "run_tests.sh") == 0, "path extracted from backticks");
  free(p3);
  check(extract_existing_path("I am not sure which file to read.") == NULL,
        "reply naming no real file is refused");
  check(extract_existing_path("/etc/passwd") == NULL, "absolute path not extracted");
  check(extract_existing_path("docs") == NULL, "directory not extracted");

  char* s1 = extract_search_pattern("tool_grep");
  check(s1 && strcmp(s1, "tool_grep") == 0, "bare search pattern extracted");
  free(s1);
  char* s2 = extract_search_pattern("Let me think about this.\nThe best string is:\n`state_append`");
  check(s2 && strcmp(s2, "state_append") == 0, "pattern taken from the last line, unquoted");
  free(s2);
  char* s3 = extract_search_pattern("\"BENDER_MAX_STEPS\"");
  check(s3 && strcmp(s3, "BENDER_MAX_STEPS") == 0, "surrounding quotes stripped");
  free(s3);
  check(extract_search_pattern("   \n  \n") == NULL, "blank reply yields no pattern");

  // Jev's answers share field names, so an unscoped search for "noul" returns
  // whichever question came first and silently discards the rest.
  const char* answers =
    "{\"model\":\"jev-1.13.0\",\"answers\":{"
    "\"action\":{\"type\":\"choice\",\"choice\":\"read_code\",\"confidence\":0.67},"
    "\"has_enough_info\":{\"type\":\"noul\",\"noul\":0.1},"
    "\"needs_code_change\":{\"type\":\"noul\",\"noul\":0.9},"
    "\"repeats\":{\"type\":\"noul\",\"noul\":0.75},"
    "\"confidence_score\":{\"type\":\"score\",\"score\":0.45,\"confidence\":0.33}}}";
  check(extract_number(answers, "has_enough_info", "\"noul\":") == 0.1, "first Noul read");
  check(extract_number(answers, "needs_code_change", "\"noul\":") == 0.9, "second Noul read, not the first");
  check(extract_number(answers, "repeats", "\"noul\":") == 0.75, "third Noul read");
  check(extract_number(answers, "action", "\"confidence\":") == 0.67, "the Choice's own confidence");
  check(extract_number(answers, "confidence_score", "\"confidence\":") == 0.33, "the Score's own confidence");
  check(extract_number(answers, "absent_question", "\"noul\":") == 0.0, "a missing question reads zero");

  // The action space is a table, not a strcmp chain: every name offered to
  // Classify must parse back to its own action, and anything else is a parse
  // failure — never a quiet fallthrough to generate_answer.
  int rt_ok = 1;
  for (int i = 0; i <= ACT_NO_FIT; i++) {
    rt_ok &= action_from_string(ACTION_NAMES[i]) == (Action)i;
  }
  check(rt_ok, "every offered action name parses back to its own Action");
  check(action_from_string("none") == ACT_NO_FIT, "none parses as the no-fit decision");
  check(action_from_string("") == ACT_UNRECOGNIZED, "empty decision is a parse failure");
  check(action_from_string("generate_answe") == ACT_UNRECOGNIZED,
        "a typo'd decision is a parse failure, not generate_answer");

  check(path_is_in_repo("sys_c.c"), "relative path allowed");
  check(!path_is_in_repo("/etc/passwd"), "absolute path refused");
  check(!path_is_in_repo("../secrets"), "parent traversal refused");
  check(!path_is_in_repo("a/../../b"), "embedded traversal refused");
  check(!path_is_in_repo(""), "empty path refused");

  char state[256];
  strcpy(state, "start");
  char big[9000];
  memset(big, 'z', sizeof(big) - 1);
  big[sizeof(big) - 1] = '\0';
  state_append(state, sizeof(state), "Big", big);
  check(strlen(state) < sizeof(state), "state_append never overruns the buffer");
  check(strncmp(state, "start", 5) == 0, "state_append preserves prior state");

  // A full buffer used to drop every later append in silence, so the agent
  // kept reasoning over a transcript that had quietly stopped growing.
  // Near-full rather than completely full: the marker needs somewhere to go,
  // and a buffer with literally no room left correctly gets none.
  char full[128];
  memset(full, 'x', 100);
  full[100] = '\0';
  state_append(full, sizeof(full), "Ignored", "this cannot fit");
  check(strstr(full, "state truncated") != NULL, "a full state says it was truncated");
  size_t after_first = strlen(full);
  state_append(full, sizeof(full), "Ignored", "nor can this");
  check(strlen(full) == after_first, "the truncation marker is written only once");

  // The file tools themselves, round-tripped on a scratch file.
  char* tmp = scratch_path("nested/f.txt");
  char* w = tool_write(tmp, "one\ntwo\nthree\n", 14);
  check(strncmp(w, "File created", 12) == 0, "tool_write creates nested dirs");
  free(w);
  char* r = tool_read(tmp, 2, 1);
  check(r && strcmp(r, "2\ttwo") == 0, "tool_read honours 1-indexed offset+limit");
  free(r);
  char* e = tool_edit(tmp, "two", "TWO", 0);
  check(strncmp(e, "The file", 8) == 0, "tool_edit applies a unique match");
  free(e);
  char* e2 = tool_edit(tmp, "nope", "x", 0);
  check(strncmp(e2, "error:", 6) == 0, "tool_edit reports a missing match as an error");
  free(e2);
  char* e3 = tool_edit(tmp, "one", "one", 0);
  check(strncmp(e3, "error:", 6) == 0, "tool_edit refuses identical old/new");
  free(e3);
  char* r2 = tool_read(tmp, 1, 0);
  check(r2 && strcmp(r2, "1\tone\n2\tTWO\n3\tthree\n4\t") == 0, "file content after edit");
  free(r2);

  // Read renders "N\tline", and a model quoting that back writes an old_string
  // the file does not contain. Edit has to recover from that or it can never
  // change a file it just read.
  char* e4 = tool_edit(tmp, "3\tthree", "THREE", 0);
  check(strncmp(e4, "The file", 8) == 0, "tool_edit strips an N<tab> line-number prefix");
  free(e4);
  char* e5 = tool_edit(tmp, "\tTHREE", "three", 0);
  check(strncmp(e5, "The file", 8) == 0, "tool_edit strips a leftover leading tab");
  free(e5);
  // A miss must say what the file actually contains, or the model has nothing
  // to correct against and proposes the same wrong text again.
  char* e_hint = tool_edit(tmp, "  check(nothing_like_this_exists);", "x", 0);
  check(strncmp(e_hint, "error:", 6) == 0, "a fabricated old_string is refused");
  check(strstr(e_hint, "no part of it appears") != NULL,
        "a wholly invented string says so rather than hinting");
  free(e_hint);
  // A realistic file: the hint anchors on a line, so it needs lines long enough
  // to identify one, which is the case it exists for.
  const char* codeish =
    "static void command_run_worker(IoWork* w) {\n"
    "  char* cmd = w->data;\n"
    "  pclose(pipe);\n"
    "  return;\n"
    "}\n";
  char* wc = tool_write(scratch_path("codeish.c"), codeish, strlen(codeish));
  free(wc);
  // The shape the agent actually failed with: right idea, invented comments
  // and indentation that is not in the file.
  char* e_near = tool_edit(scratch_path("codeish.c"),
                           "    // close pipe and ignore exit status\n    pclose(pipe);\n", "x", 0);
  check(e_near && strstr(e_near, "closest text found") != NULL,
        "a near miss reports the closest real text");
  check(e_near && strstr(e_near, "3:  pclose(pipe);") != NULL,
        "the hint shows the real line, numbered, at its real position");
  free(e_near);

  char* e6 = tool_edit(tmp, "12:absent", "x", 0);
  check(strncmp(e6, "error:", 6) == 0, "stripping does not invent a match that is not there");
  free(e6);
  // The exact text must still win over the stripped reading.
  const char* numbered_looking = "one\nTWO\nthree\n9\tnine\n";
  char* w2 = tool_write(tmp, numbered_looking, strlen(numbered_looking));
  free(w2);
  char* e7 = tool_edit(tmp, "9\tnine", "NINE", 0);
  check(strncmp(e7, "The file", 8) == 0, "an exact match that looks numbered is taken literally");
  free(e7);
  char* r3 = tool_read(tmp, 4, 1);
  check(r3 && strcmp(r3, "4\tNINE") == 0, "the literal line was replaced, not a stripped one");
  free(r3);

  // ----------------------------------------------------------------------
  // Grep: test pattern matching, non‑matching, and directory handling.
  // ----------------------------------------------------------------------
  // The file currently contains:
  //   one
  //   TWO
  //   three
  //   9    NINE
  // Grep for a line that exists. Hits now carry their context lines, marked
  // '-' the way grep -C marks them, so a match lands in the state with the
  // code around it — a bare "N:line" left the model to invent what contained
  // the match.
  char* g1 = tool_grep("TWO", tmp);
  check(g1 && strcmp(g1, "1-one\n2:TWO\n3-three\n4-NINE") == 0,
        "tool_grep matches pattern, with context lines around it");
  free(g1);

  // Blocks that do not touch are separated the way grep separates them.
  const char* far_text = "aa hit bb\nx\nx\nx\nx\nx\nx\nx\nx\nzz hit yy\n";
  char* w_far = tool_write(scratch_path("far.txt"), far_text, strlen(far_text));
  free(w_far);
  char* g_gap = tool_grep("hit", scratch_path("far.txt"));
  check(g_gap && strstr(g_gap, "1:aa hit bb") != NULL &&
        strstr(g_gap, "\n--\n") != NULL && strstr(g_gap, "10:zz hit yy") != NULL,
        "tool_grep separates distant match blocks with --");
  free(g_gap);

  // A miss retries case-insensitively and says so when that finds something.
  const char* ci_text = "foo\nBender_MAX\nbar\n";
  char* w_ci = tool_write(scratch_path("ci.txt"), ci_text, strlen(ci_text));
  free(w_ci);
  char* g_ci = tool_grep("BENDER_MAX", scratch_path("ci.txt"));
  check(g_ci && strstr(g_ci, "No matches found") != NULL &&
        strstr(g_ci, "case-insensitive") != NULL &&
        strstr(g_ci, "2:Bender_MAX") != NULL,
        "a case-only miss retries case-insensitively and reports it");
  free(g_ci);

  // A complete miss reports the longest pieces of the pattern that do appear,
  // so the next guess starts from something real instead of another shot in
  // the dark — the failure this exists to prevent was six identical misses.
  const char* const_text = "#define BENDER_GREP_MAX_MATCHES 200\n";
  char* w_const = tool_write(scratch_path("const.h"), const_text, strlen(const_text));
  free(w_const);
  char* g_frag = tool_grep("MAX_GREP_MATCHES", scratch_path("const.h"));
  check(g_frag && strstr(g_frag, "No matches found") != NULL &&
        strstr(g_frag, "'MAX_'") != NULL && strstr(g_frag, "'_MATCHES'") != NULL,
        "a miss names the longest pieces of the pattern that do appear");
  free(g_frag);

  // Over a tree the same hint names the files a piece lives in. The pattern
  // is concatenated here so this file does not contain it literally.
  char* g_tree = tool_grep("QQMAX_" "MATCHES", ".");
  check(g_tree && strstr(g_tree, "No matches found") != NULL &&
        strstr(g_tree, "'MAX_MATCHES'") != NULL && strstr(g_tree, "tools_c.h") != NULL,
        "a tree miss names the files holding a matching piece");
  free(g_tree);

  // When no piece long enough to mean anything appears, the miss stays plain.
  char* g_plain = tool_grep("q9z8w7", tmp);
  check(g_plain && strstr(g_plain, "No matches found") != NULL &&
        strstr(g_plain, "Pieces") == NULL,
        "a miss with no real pieces stays a plain message");
  free(g_plain);

  // Grep for a pattern that does not exist.
  char* g2 = tool_grep("absent", tmp);
  check(g2 && strstr(g2, "No matches found") != NULL,
        "tool_grep reports no matches");
  free(g2);

  // A directory searches the tree beneath it and labels each hit with its path,
  // which is what makes grep useful for finding a file rather than guessing one.
  char* g3 = tool_grep("NINE", scratch);
  check(g3 && strstr(g3, "nested/f.txt:4:NINE") != NULL,
        "tool_grep on a directory searches the tree and labels hits with the path");
  free(g3);

  // A tree search covers tracked files only, so generated output cannot crowd
  // out the source it was generated from.
  char* g_tracked = tool_grep("BENDER_GREP_MAX_MATCHES", ".");
  check(g_tracked && strstr(g_tracked, "tools_c.h:") != NULL,
        "a tree search finds tracked source");
  // A hit in an untracked file would label lines with its path; the name can
  // still occur inside another file's context lines (it does — this very
  // check), so the assertion looks at the label position, not the substring.
  check(g_tracked && strncmp(g_tracked, "agent_primitives.c", 18) != 0 &&
        strstr(g_tracked, "\nagent_primitives.c") == NULL,
        "a tree search skips generated, untracked files");
  free(g_tracked);
  // The tracked filter is about this repository; an absolute path is somewhere
  // else and must not be filtered by it, or scratch directories vanish.
  char* g_abs = tool_grep("NINE", scratch);
  check(g_abs && strstr(g_abs, "f.txt:4:NINE") != NULL,
        "an absolute path is searched without the tracked filter");
  free(g_abs);

  char* g4 = tool_grep("", tmp);
  check(strncmp(g4, "error:", 6) == 0, "tool_grep refuses an empty pattern");
  free(g4);

  char* g5 = tool_grep("x", scratch_path("no_such_file"));
  check(strncmp(g5, "error:", 6) == 0, "tool_grep reports a missing path as an error");
  free(g5);

  // A very long match is clipped so one minified line cannot swamp the state.
  char long_line[BENDER_GREP_MAX_LINE + 200];
  memset(long_line, 'q', sizeof(long_line) - 1);
  long_line[sizeof(long_line) - 1] = '\0';
  memcpy(long_line, "needle", 6);
  char* w3 = tool_write(scratch_path("long.txt"), long_line, strlen(long_line));
  free(w3);
  char* g6 = tool_grep("needle", scratch_path("long.txt"));
  check(g6 && strlen(g6) < BENDER_GREP_MAX_LINE + 64, "tool_grep clips an over-long line");
  check(g6 && strstr(g6, "...") != NULL, "tool_grep marks a clipped line");
  free(g6);

  // A binary file has no lines worth showing and is skipped rather than dumped.
  char nul_bytes[16] = {'h','i',0,'m','a','t','c','h',0,0,0,0,0,0,0,0};
  char* w4 = tool_write(scratch_path("bin.dat"), nul_bytes, sizeof(nul_bytes));
  free(w4);
  char* g7 = tool_grep("match", scratch_path("bin.dat"));
  check(g7 && strncmp(g7, "No matches", 10) == 0, "tool_grep skips a binary file");
  free(g7);

  printf("\n%d failure(s)\n", fails);
  return fails != 0;
}
