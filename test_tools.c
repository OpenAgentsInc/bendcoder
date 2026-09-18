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

int main(void) {
  system("rm -rf /tmp/bender_tool_test");

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

  // The file tools themselves, round-tripped on a scratch file.
  const char* tmp = "/tmp/bender_tool_test/nested/f.txt";
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
  char* g3 = tool_grep("NINE", "/tmp/bender_tool_test");
  check(g3 && strstr(g3, "/tmp/bender_tool_test/nested/f.txt:4:NINE") != NULL,
        "tool_grep on a directory searches the tree and labels hits with the path");
  free(g3);

  char* g4 = tool_grep("", tmp);
  check(strncmp(g4, "error:", 6) == 0, "tool_grep refuses an empty pattern");
  free(g4);

  char* g5 = tool_grep("x", "/tmp/bender_tool_test/no_such_file");
  check(strncmp(g5, "error:", 6) == 0, "tool_grep reports a missing path as an error");
  free(g5);

  // A very long match is clipped so one minified line cannot swamp the state.
  char long_line[BENDER_GREP_MAX_LINE + 200];
  memset(long_line, 'q', sizeof(long_line) - 1);
  long_line[sizeof(long_line) - 1] = '\0';
  memcpy(long_line, "needle", 6);
  char* w3 = tool_write("/tmp/bender_tool_test/long.txt", long_line, strlen(long_line));
  free(w3);
  char* g6 = tool_grep("needle", "/tmp/bender_tool_test/long.txt");
  check(g6 && strlen(g6) < BENDER_GREP_MAX_LINE + 64, "tool_grep clips an over-long line");
  check(g6 && strstr(g6, "...") != NULL, "tool_grep marks a clipped line");
  free(g6);

  // A binary file has no lines worth showing and is skipped rather than dumped.
  char nul_bytes[16] = {'h','i',0,'m','a','t','c','h',0,0,0,0,0,0,0,0};
  char* w4 = tool_write("/tmp/bender_tool_test/bin.dat", nul_bytes, sizeof(nul_bytes));
  free(w4);
  char* g7 = tool_grep("match", "/tmp/bender_tool_test/bin.dat");
  check(g7 && strncmp(g7, "No matches", 10) == 0, "tool_grep skips a binary file");
  free(g7);

  printf("\n%d failure(s)\n", fails);
  return fails != 0;
}
