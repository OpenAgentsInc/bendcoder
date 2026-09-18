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

  // The file Choice's options are the repository listing itself: files that
  // exist are offered with a first-line description, anything else is filtered
  // out, and "none" is always there so Jev can decline (#26).
  FILE* cf = tmpfile();
  check(cf != NULL, "criteria scratch file");
  int offered = emit_file_criteria(cf, "tools_c.h\ndocs\nno_such_file.xyz\n../escape\n");
  fflush(cf);
  rewind(cf);
  char crit[8192];
  size_t crit_len = fread(crit, 1, sizeof(crit) - 1, cf);
  crit[crit_len] = '\0';
  fclose(cf);
  check(strstr(crit, "\"tools_c.h\":\"") != NULL, "a tracked file is offered with a description");
  check(offered == 1, "only the real file counts as an option");
  check(strstr(crit, "no_such_file") == NULL, "a missing file is not offered");
  check(strstr(crit, "\"docs\"") == NULL, "a directory is not offered");
  check(strstr(crit, "escape") == NULL, "a path outside the repo is not offered");
  check(strstr(crit, "\"none\":") != NULL, "none is always offered");

  // A file read to the end drops out of the options so Jev cannot pick it again.
  ReadCursor* done = read_cursor_for("tools_c.h");
  check(done != NULL, "cursor for tools_c.h");
  done->exhausted = 1;
  FILE* cf2 = tmpfile();
  emit_file_criteria(cf2, "tools_c.h\nREADME.md\n");
  fflush(cf2);
  rewind(cf2);
  size_t crit2_len = fread(crit, 1, sizeof(crit) - 1, cf2);
  crit[crit2_len] = '\0';
  fclose(cf2);
  check(strstr(crit, "tools_c.h") == NULL, "an exhausted file is not offered again");
  check(strstr(crit, "README.md") != NULL, "an unfinished file is still offered");

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

  // The answers-to-action table: the same rows selector.bend pins with laws.
  // route_decision(choice, conf, noul, repeats, risk, asked, read_phase, last).
  check(route_decision("read_code", 0.9, 0.1, 0.1, 0.2, 0.1, 1, "", 0).act == ACT_READ_CODE,
        "a confident read acts");
  check(route_decision("read_code", 0.5, 0.1, 0.1, 0.2, 0.1, 1, "", 0).act == ACT_READ_CODE,
        "a mid-confidence read acts");
  check(route_decision("apply_edit", 0.5, 0.1, 0.1, 0.2, 0.9, 1, "", 0).act == ACT_READ_CODE,
        "the same confidence under the edit floor re-reads");
  check(route_decision("generate_answer", 0.3, 0.9, 0.1, 0.2, 0.9, 1, "", 0).act == ACT_READ_CODE,
        "confidence under the floor re-reads rather than acting");
  check(route_decision("task_complete", 0.3, 0.9, 0.1, 0.2, 0.9, 1, "", 0).act == ACT_TASK_COMPLETE,
        "a decision to stop is not rerouted by the floor");
  check(route_decision("search_code", 0.9, 0.1, 0.9, 0.2, 0.1, 1, "search_code", 0).act == ACT_READ_CODE,
        "repeats high does not take that action again");
  check(route_decision("apply_edit", 0.9, 0.1, 0.1, 1.8, 0.1, 1, "", 0).act == ACT_READ_CODE,
        "top-level risk the goal did not ask for is not run");
  check(route_decision("apply_edit", 0.9, 0.1, 0.1, 1.8, 0.9, 1, "", 0).act == ACT_APPLY_EDIT,
        "top-level risk the goal asked for runs");
  check(route_decision("apply_edit", 0.9, 0.1, 0.1, 0.2, 0.9, 0, "", 0).act == ACT_READ_CODE,
        "an edit before the first read reads first");
  check(route_decision("generate_answer", 0.9, 0.1, 0.1, 0.2, 0.9, 0, "", 0).act == ACT_READ_CODE,
        "an answer on too little information with nothing read reads first");
  check(route_decision("none", 0.9, 0.1, 0.9, 1.8, 0.1, 1, "none", 0).act == ACT_NO_FIT,
        "none passes through to the dispatch halt");
  // The search-miss row: enough consecutive misses turns a search into a read,
  // which is the deterministic sibling of the repeats row beside it (#9).
  check(route_decision("search_code", 0.9, 0.1, 0.1, 0.2, 0.1, 1, "", 0).act == ACT_SEARCH_CODE,
        "a search with no misses behind it runs");
  check(route_decision("search_code", 0.9, 0.1, 0.1, 0.2, 0.1, 1, "", 2).act == ACT_READ_CODE,
        "a search after two misses in a row becomes a read");

  check(route_decision("bogus", 0.9, 0.1, 0.1, 0.2, 0.1, 1, "", 0).act == ACT_UNRECOGNIZED,
        "a decision naming no action passes through to the dispatch halt");

  check(path_is_in_repo("sys_c.c"), "relative path allowed");
  check(!path_is_in_repo("/etc/passwd"), "absolute path refused");
  check(!path_is_in_repo("../secrets"), "parent traversal refused");
  check(!path_is_in_repo("a/../../b"), "embedded traversal refused");
  check(!path_is_in_repo(""), "empty path refused");

  // The coverage manifest run_tests.sh ends with is what lets apply_edit tell
  // a real verification from a green run over a file nothing checks (#22).
  const char* cov_out =
    "== suite coverage ==\n"
    "COVERED: README.md\n"
    "COVERED: bender_agent.c\n"
    "COVERED: tools_c.h\n"
    "All checks passed.\n";
  check(suite_covers(cov_out, "tools_c.h") == 1, "a file in the manifest reads as covered");
  check(suite_covers(cov_out, "README.md") == 1, "the manifest's first entry reads as covered");
  check(suite_covers(cov_out, "LICENSE") == 0, "a file outside the manifest reads as uncovered");
  check(suite_covers(cov_out, "tools_c") == 0, "a prefix of a covered name is not covered");
  check(suite_covers(cov_out, "./tools_c.h") == 1, "a ./ prefix still resolves against the manifest");
  check(suite_covers("All checks passed.\n", "tools_c.h") == -1,
        "output with no manifest reads as unknown coverage");
  check(suite_covers(NULL, "tools_c.h") == -1, "a NULL output has no manifest");

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

  // ----------------------------------------------------------------------
  // The anchored edit: line ids, exact bytes, and the route to the fallback.
  // ----------------------------------------------------------------------

  // split_lines counts lines the way tool_read renders them: a trailing
  // newline yields a final empty line, and spans keep their '\r' so the
  // window's bytes stay the file's own.
  const char* ltext = "one\ntwo\nthree\n";
  long ln = 0;
  LineSpan* ls = split_lines(ltext, strlen(ltext), &ln);
  check(ls && ln == 4, "a trailing newline yields a final empty line");
  check(ls && ls[0].len == 3 && ls[3].len == 0, "line spans carry their own lengths");
  free(ls);
  const char* noeol = "alpha\nbeta";
  ls = split_lines(noeol, strlen(noeol), &ln);
  check(ls && ln == 2, "no trailing newline means no trailing empty line");
  check(ls && ls[1].len == 4, "the last span runs to the end of the buffer");
  free(ls);

  // window_text joins the exact bytes of a line range — the text the file
  // holds between those boundaries, never a model's transcription of it.
  ls = split_lines(ltext, strlen(ltext), &ln);
  char* wt = window_text(ls, 1, 2);
  check(wt && strcmp(wt, "one\ntwo") == 0, "a two-line window yields the file's exact bytes");
  free(wt);
  wt = window_text(ls, 3, 3);
  check(wt && strcmp(wt, "three") == 0, "a one-line window is that line");
  free(wt);

  // occurs_in counts the way tool_edit's uniqueness check does, so a window
  // that counts once here is accepted there.
  check(occurs_in("dup\ndup\nuniq\n", "dup") == 2, "occurrences count non-overlapping matches");
  check(occurs_in("dup\ndup\nuniq\n", "dup\ndup") == 1, "a wider window counts once");
  check(occurs_in("anything", "") == 0, "an empty needle counts zero");
  check(occurs_in("aaaa", "aa") == 2, "non-overlapping pairs, not overlapping ones");

  // unique_window grows the anchor's window until its bytes occur exactly
  // once: a unique line is taken alone, a duplicated one takes its
  // neighbours, and the whole file is the last resort.
  const char* dupfile = "dup\ndup\nuniq\ntail\n";
  long dn = 0;
  LineSpan* dl = split_lines(dupfile, strlen(dupfile), &dn);
  char* uw = unique_window(dl, dn, 3, dupfile);
  check(uw && strcmp(uw, "uniq") == 0, "a unique anchor line is its own window");
  free(uw);
  uw = unique_window(dl, dn, 1, dupfile);
  check(uw && strcmp(uw, "dup\ndup") == 0, "a duplicated line widens until unique");
  free(uw);
  free(dl);
  free(ls);

  // A line id is all digits, matching U32.read on the Bend side.
  long lid = 0;
  check(parse_line_id("42", &lid) && lid == 42, "a numeric label parses");
  check(!parse_line_id("+7", &lid), "a signed label does not parse");
  check(!parse_line_id("-3", &lid), "a negative label does not parse");
  check(!parse_line_id("7x", &lid), "a trailing character does not parse");
  check(!parse_line_id("", &lid), "an empty label does not parse");

  // jev_pick_label: only a confident, non-"none" Choice reads as a pick.
  JevAnswer pc = { JEV_CHOSEN, "sys_c.c", 0.9, 0.0, 0.0 };
  char* pl = jev_pick_label(pc, BENDER_EDIT_FILE_FLOOR);
  check(pl && strcmp(pl, "sys_c.c") == 0, "a confident choice yields its label");
  free(pl);
  JevAnswer pn = { JEV_CHOSEN, "none", 0.9, 0.0, 0.0 };
  check(jev_pick_label(pn, BENDER_EDIT_FILE_FLOOR) == NULL, "none is no pick");
  JevAnswer plow = { JEV_CHOSEN, "sys_c.c", 0.1, 0.0, 0.0 };
  check(jev_pick_label(plow, BENDER_EDIT_FILE_FLOOR) == NULL, "low confidence is no pick");
  JevAnswer pms = { JEV_MISSING, "rate limited", 0.0, 0.0, 0.0 };
  check(jev_pick_label(pms, BENDER_EDIT_FILE_FLOOR) == NULL, "a missing answer is no pick");

  // anchor_route mirrors the Bend gate's row order: an unparseable label
  // wins first, then absence over low confidence, and only a confident
  // anchor over a present file keeps its line.
  const char* ar_reason = NULL;
  long ar_line = 0;
  JevAnswer good_c = { JEV_CHOSEN, "7", 0.9, 0.0, 0.0 };
  JevAnswer present = { JEV_NOULED, "", 0.0, 0.0, 0.95 };
  JevAnswer absent = { JEV_NOULED, "", 0.0, 0.0, 0.05 };
  check(anchor_route(good_c, present, &ar_line, &ar_reason) == 1 && ar_line == 7,
        "a confident anchor over a present file keeps its line");
  check(anchor_route(good_c, absent, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "does not contain") != NULL,
        "an absent file sends the edit back");
  JevAnswer low_c = { JEV_CHOSEN, "7", 0.3, 0.0, 0.0 };
  check(anchor_route(low_c, present, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "not confident enough") != NULL,
        "an under-floor anchor sends the edit back");
  check(anchor_route(low_c, absent, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "does not contain") != NULL,
        "absence wins over low confidence");
  JevAnswer bogus_c = { JEV_CHOSEN, "bogus", 0.9, 0.0, 0.0 };
  check(anchor_route(bogus_c, present, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "named no line") != NULL,
        "an unparseable label sends the edit back");
  check(anchor_route(bogus_c, absent, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "named no line") != NULL,
        "an unparseable label wins over absence");
  JevAnswer missing_c = { JEV_MISSING, "rate limited", 0.0, 0.0, 0.0 };
  check(anchor_route(missing_c, present, &ar_line, &ar_reason) == 0 &&
        strstr(ar_reason, "rate limited") != NULL,
        "a missing anchor sends the edit back with its reason");

  // The line criteria are the cookbook's tags: each line's number is the
  // option's label and its own text the description.
  ls = split_lines(ltext, strlen(ltext), &ln);
  FILE* lf = tmpfile();
  int lopts = emit_line_criteria(lf, ls, 1, ln);
  fflush(lf);
  rewind(lf);
  char lcrit[8192];
  size_t lcrit_len = fread(lcrit, 1, sizeof(lcrit) - 1, lf);
  lcrit[lcrit_len] = '\0';
  fclose(lf);
  check(lopts == 4, "one option per line of the window");
  check(strstr(lcrit, "\"2\":\"two\"") != NULL, "a line's number labels its text");
  check(strstr(lcrit, "\"4\":\"\"") != NULL, "the trailing empty line is still offered");
  free(ls);

  // The window criteria page the line ids under the Choice cap, labelled by
  // the line each range starts at, with `none` kept for the escape hatch.
  FILE* wf = tmpfile();
  int wopts = emit_window_criteria(wf, 560, BENDER_ANCHOR_PAGE);
  fflush(wf);
  rewind(wf);
  char wcrit[8192];
  size_t wcrit_len = fread(wcrit, 1, sizeof(wcrit) - 1, wf);
  wcrit[wcrit_len] = '\0';
  fclose(wf);
  check(wopts == 3, "560 lines is three 200-line windows");
  check(strstr(wcrit, "\"1\":\"lines 1 to 200\"") != NULL, "the first window's label and range");
  check(strstr(wcrit, "\"401\":\"lines 401 to 560\"") != NULL, "the last window stops at the file's end");
  check(strstr(wcrit, "\"none\":") != NULL, "none is always offered");

  // The edit file criteria offer real files with first-line descriptions,
  // like the read picker's, but a file read to the end stays offerable —
  // it is still a file the change can belong in.
  FILE* ef = tmpfile();
  int eopts = emit_edit_file_criteria(ef, "tools_c.h\nREADME.md\ndocs\n../escape\n");
  fflush(ef);
  rewind(ef);
  char ecrit[8192];
  size_t ecrit_len = fread(ecrit, 1, sizeof(ecrit) - 1, ef);
  ecrit[ecrit_len] = '\0';
  fclose(ef);
  check(eopts == 2, "the edit picker offers the real files");
  check(strstr(ecrit, "\"tools_c.h\":\"") != NULL, "an exhausted file is still an edit target");
  check(strstr(ecrit, "\"docs\"") == NULL, "a directory is not an edit target");
  check(strstr(ecrit, "escape") == NULL, "a path outside the repo is not an edit target");
  check(strstr(ecrit, "\"none\":") != NULL, "none is always offered to the edit picker");

  // extract_new_str drops the one trailing newline a reply frame adds.
  char* ns = extract_new_str("int a = 2;\n");
  check(ns && strcmp(ns, "int a = 2;") == 0, "one trailing newline is framing, dropped");
  free(ns);
  ns = extract_new_str("int a = 2;");
  check(ns && strcmp(ns, "int a = 2;") == 0, "a reply without the newline is verbatim");
  free(ns);
  ns = extract_new_str("line one\nline two\n\n");
  check(ns && strcmp(ns, "line one\nline two\n") == 0, "only the framing newline is dropped");
  free(ns);

  printf("\n%d failure(s)\n", fails);
  return fails != 0;
}
