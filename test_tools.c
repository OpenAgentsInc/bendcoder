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

  // An edit may carry several hunks — one PATH/OLD/NEW group per file or per
  // spot — before the single <<<END>>>; they are parsed and applied as a unit.
  const char* multi =
    "<<<PATH>>>\nsys_c.c\n<<<OLD>>>\nint a = 1;\n<<<NEW>>>\nint a = 2;\n"
    "<<<PATH>>>\nagent_primitives.bend\n<<<OLD>>>\nold\n  kept\n<<<NEW>>>\nnew\n<<<END>>>\n";
  EditHunk* hs = NULL;
  int hn = parse_edit_hunks(multi, &hs);
  check(hn == 2, "a two-hunk block parses both hunks");
  check(hs && hn == 2 && strcmp(hs[0].path, "sys_c.c") == 0 &&
        strcmp(hs[0].old_str, "int a = 1;") == 0 && strcmp(hs[0].new_str, "int a = 2;") == 0,
        "the first hunk keeps its own fields");
  check(hs && hn == 2 && strcmp(hs[1].path, "agent_primitives.bend") == 0 &&
        strcmp(hs[1].old_str, "old\n  kept") == 0 && strcmp(hs[1].new_str, "new") == 0,
        "the second group is not folded into the first NEW");
  free_edit_hunks(hs, hn);

  // The common one-hunk reply still parses, and <<<END>>> ends it — anything
  // after is ignored, so a model's trailing note cannot become a hunk.
  EditHunk* one = NULL;
  int on = parse_edit_hunks(
    "<<<PATH>>>\nsrc/a.c\n<<<OLD>>>\nint x = 1;\n<<<NEW>>>\nint x = 42;\n"
    "<<<END>>>\n<<<PATH>>>\nstray.c\n<<<OLD>>>\nz\n<<<NEW>>>\nw\n", &one);
  check(on == 1 && one && strcmp(one[0].new_str, "int x = 42;") == 0,
        "a single-hunk block parses and ignores text after <<<END>>>");
  free_edit_hunks(one, on);

  EditHunk* bad = NULL;
  check(parse_edit_hunks("<<<PATH>>>\nx.c\n<<<OLD>>>\na\n", &bad) == -1,
        "a group missing <<<NEW>>> is malformed");
  check(parse_edit_hunks("<<<PATH>>>\nx.c\n<<<OLD>>>\na\n<<<NEW>>>\nb\n", &bad) == -1,
        "a group missing <<<END>>> is malformed");
  check(parse_edit_hunks("no sentinels at all", &bad) == -1,
        "a reply with no group is malformed");
  check(parse_edit_hunks("<<<PATH>>>\nx.c\n<<<PATH>>>\ny.c\n<<<OLD>>>\na\n<<<NEW>>>\nb\n<<<END>>>\n",
                         &bad) == -1,
        "a group missing <<<OLD>>> is malformed");

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

  // jev_answer returns the same fields as one typed value, with the kind the
  // loop switches on. See #34.
  JevAnswer ja = jev_answer(answers, "action");
  check(ja.kind == JEV_CHOSEN && strcmp(ja.text, "read_code") == 0 &&
        ja.confidence == 0.67, "the Choice answer reads as JEV_CHOSEN");
  JevAnswer jn = jev_answer(answers, "needs_code_change");
  check(jn.kind == JEV_NOULED && jn.probability == 0.9,
        "the second Noul reads as JEV_NOULED, not the first");
  JevAnswer js = jev_answer(answers, "confidence_score");
  check(js.kind == JEV_SCORED && js.score == 0.45 && js.confidence == 0.33,
        "the Score answer reads as JEV_SCORED");
  JevAnswer jm = jev_answer(answers, "absent_question");
  check(jm.kind == JEV_MISSING && jm.text[0] != '\0',
        "an unanswered question is JEV_MISSING with a reason");
  JevAnswer je = jev_answer("{\"error\":\"rate limited\",\"retry-after-ms\":5000}", "action");
  check(je.kind == JEV_MISSING && strstr(je.text, "rate limited") != NULL,
        "a failed request is JEV_MISSING carrying the error as its reason");

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

  // Rollback covers the set of files a batch touches: each path is snapshotted
  // once before its first hunk, changed files are restored, and a file the
  // batch created is removed — the unit, not whichever hunk failed.
  char* sf1 = scratch_path("snap/a.txt");
  char* sf2 = scratch_path("snap/b.txt");
  char* sw = tool_write(sf1, "before\n", 7);
  free(sw);
  FileSnapshot* sn = calloc(2, sizeof(FileSnapshot));
  int sn_n = 0;
  check(snapshot_for(sn, &sn_n, sf1) != NULL && sn_n == 1, "snapshot taken for a touched file");
  check(snapshot_for(sn, &sn_n, sf1) == &sn[0] && sn_n == 1,
        "a second hunk on one file does not re-snapshot");
  check(snapshot_for(sn, &sn_n, sf2) != NULL && sn_n == 2 && sn[1].data == NULL,
        "a not-yet-existing file snapshots as absent");
  char* m1 = tool_edit(sf1, "before", "after", 0);
  free(m1);
  char* m2 = tool_write(sf2, "created\n", 8);
  free(m2);
  snapshots_restore(sn, sn_n);
  char* back = bender_slurp(sf1, NULL);
  check(back && strcmp(back, "before\n") == 0, "a changed file is restored on rollback");
  check(!bender_exists(sf2), "a file the batch created is removed on rollback");
  free(back);
  snapshots_free(sn, sn_n);
  free(sf1);
  free(sf2);

  // ----------------------------------------------------------------------
  // Grep: test pattern matching, non‑matching, and directory handling.
  // ----------------------------------------------------------------------
  // The file currently contains:
  //   one
  //   TWO
  //   three
  //   9    NINE
  // Grep for a line that exists.
  char* g1 = tool_grep("TWO", tmp);
  check(g1 && strcmp(g1, "2:TWO") == 0, "tool_grep matches pattern");
  free(g1);

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
  check(g_tracked && strstr(g_tracked, "agent_primitives.c:") == NULL,
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
