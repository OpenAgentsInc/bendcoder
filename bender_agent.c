// Unified Bender Runtime Runner in C
// Combines TypeSafe System One, OpenRouter, and System tools into a clean terminal UI loop
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <ctype.h>

// Read / Write / Edit, shared with the Bend FFI layer in sys_c.c.
#include "tools_c.h"

#define ANSI_CYAN    "\x1b[36m"
#define ANSI_GREEN   "\x1b[32m"
#define ANSI_YELLOW  "\x1b[33m"
#define ANSI_MAGENTA "\x1b[35m"
#define ANSI_BOLD    "\x1b[1m"
#define ANSI_DIM     "\x1b[2m"
#define ANSI_RESET   "\x1b[0m"

static void render_banner(void) {
  printf("%s================================================================================%s\n", ANSI_CYAN, ANSI_RESET);
  printf("%s  🤖 [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)%s\n", ANSI_BOLD, ANSI_RESET);
  printf("%s================================================================================%s\n", ANSI_CYAN, ANSI_RESET);
}

// Low-level helper: execute shell command and capture combined stdout/stderr.
// *status, when given, receives the command's exit code so a caller can tell a
// clean build from a failing one without reading the output.
static char* exec_cmd_status(const char* cmd, int* status) {
  if (status) *status = -1;
  char full_cmd[4096];
  snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", cmd);
  FILE* p = popen(full_cmd, "r");
  if (!p) return strdup("[failed to execute]");
  size_t cap = 2048;
  size_t len = 0;
  char* out = malloc(cap);
  char chunk[1024];
  size_t bytes;
  while ((bytes = fread(chunk, 1, sizeof(chunk), p)) > 0) {
    if (len + bytes + 1 >= cap) {
      cap = (cap + bytes) * 2;
      out = realloc(out, cap);
    }
    memcpy(out + len, chunk, bytes);
    len += bytes;
    out[len] = '\0';
  }
  int rc = pclose(p);
  if (status) *status = (rc == -1) ? -1 : WEXITSTATUS(rc);
  return out;
}

static char* exec_cmd(const char* cmd) {
  return exec_cmd_status(cmd, NULL);
}

// Read API key from env or file
static const char* get_api_key(const char* env_var, const char* file_path, char* buf, size_t buf_sz) {
  const char* k = getenv(env_var);
  if (k && strlen(k) > 0) return k;
  FILE* f = fopen(file_path, "r");
  if (!f) return NULL;
  char line[256];
  while (fgets(line, sizeof(line), f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char* nl = strchr(line, '\r'); if (nl) *nl = '\0';
    nl = strchr(line, '\n'); if (nl) *nl = '\0';
    if (strlen(line) > 0) {
      strncpy(buf, line, buf_sz - 1);
      buf[buf_sz - 1] = '\0';
      fclose(f);
      return buf;
    }
  }
  fclose(f);
  return NULL;
}

// Call TypeSafe System One
static char* call_typesafe_classify(const char* state_str) {
  char key_buf[256];
  const char* key = get_api_key("TYPESAFE_API_KEY", ".env.typesafe", key_buf, sizeof(key_buf));
  if (!key) return strdup("{\"error\": \"Missing TypeSafe key\"}");

  char tmp_payload[] = "/tmp/bender_ts_XXXXXX";
  int fd = mkstemp(tmp_payload);
  if (fd < 0) return strdup("{}");
  FILE* pf = fdopen(fd, "w");
  if (pf) {
    fprintf(pf, "{\"model\":\"jev-latest\",\"state\":");
    fputc('\"', pf);
    for (const char* p = state_str; *p; p++) {
      if (*p == '\"') fputs("\\\"", pf);
      else if (*p == '\\') fputs("\\\\", pf);
      else if (*p == '\n') fputs("\\n", pf);
      else if (*p == '\r') fputs("\\r", pf);
      else if (*p == '\t') fputs("\\t", pf);
      else fputc(*p, pf);
    }
    fputs("\",\"questions\":{"
      "\"action\":{\"type\":\"choice\",\"instructions\":\"Given the user question or goal and current state, what is the single next best action to take?\","
      "\"criteria\":{"
        "\"read_code\":\"Inspect files, repository contents, or directory listings to gather needed facts\","
        "\"search_code\":\"Search the repository for a literal string to find which files are relevant\","
        "\"run_build\":\"Run a shell command, test, or build to inspect output\","
        "\"apply_edit\":\"Change the code on disk: the fix is understood and a concrete edit to a known file can be written now\","
        "\"generate_answer\":\"Synthesize the final answer, explanation, or code using the LLM\","
        "\"task_complete\":\"The user request has already been completely answered and verified\"}},"
      "\"has_enough_info\":{\"type\":\"noul\",\"instructions\":\"Does the current state have enough concrete information to directly answer the user prompt?\"},"
      "\"needs_code_change\":{\"type\":\"noul\",\"instructions\":\"Does satisfying this goal require editing files in this repository, rather than only answering in prose?\"},"
      "\"confidence_score\":{\"type\":\"score\",\"instructions\":\"How confident are we that we can answer or finish now?\","
      "\"criteria\":[\"0: Need more information from files or commands\",\"1: Partially understood\",\"2: Fully ready to answer or complete\"]}"
    "}}", pf);
    fflush(pf);
    fclose(pf);
  }

  char cmd[4096];
  snprintf(cmd, sizeof(cmd),
    "curl -s -X POST https://api.typesafe.ai/v1/systemone "
    "-H 'Authorization: Bearer %s' "
    "-H 'Content-Type: application/json' "
    "-d @%s",
    key, tmp_payload);

  char* resp = exec_cmd(cmd);
  unlink(tmp_payload);
  return resp;
}

// Call OpenRouter Chat Completion
static char* call_openrouter_with_system(const char* system_prompt, const char* prompt) {
  char key_buf[256];
  const char* key = get_api_key("OPENROUTER_API_KEY", ".env.openrouter", key_buf, sizeof(key_buf));
  if (!key) return strdup("{\"error\": \"Missing OpenRouter key\"}");

  // OPENROUTER_MODEL and OPENROUTER_BACKUP_MODEL override the defaults.
  const char* model = getenv("OPENROUTER_MODEL");
  if (!model || !model[0]) model = "openai/gpt-oss-120b:nitro";
  const char* backup = getenv("OPENROUTER_BACKUP_MODEL");
  if (!backup || !backup[0]) backup = "deepseek/deepseek-v4-flash-0731:free";

  char tmp_payload[] = "/tmp/bender_or_XXXXXX";
  int fd = mkstemp(tmp_payload);
  if (fd < 0) return strdup("{}");
  FILE* pf = fdopen(fd, "w");
  if (pf) {
    fprintf(pf, "{\"model\":\"%s\",\"models\":[\"%s\",\"%s\"],\"messages\":["
      "{\"role\":\"system\",\"content\":", model, model, backup);
    fputc('\"', pf);
    for (const char* p = system_prompt; *p; p++) {
      if (*p == '\"') fputs("\\\"", pf);
      else if (*p == '\\') fputs("\\\\", pf);
      else if (*p == '\n') fputs("\\n", pf);
      else if (*p == '\r') fputs("\\r", pf);
      else if (*p == '\t') fputs("\\t", pf);
      else fputc(*p, pf);
    }
    fputs("\"},{\"role\":\"user\",\"content\":", pf);
    fputc('\"', pf);
    for (const char* p = prompt; *p; p++) {
      if (*p == '\"') fputs("\\\"", pf);
      else if (*p == '\\') fputs("\\\\", pf);
      else if (*p == '\n') fputs("\\n", pf);
      else if (*p == '\r') fputs("\\r", pf);
      else if (*p == '\t') fputs("\\t", pf);
      else fputc(*p, pf);
    }
    fputs("\"}]}", pf);
    fflush(pf);
    fclose(pf);
  }

  char cmd[4096];
  snprintf(cmd, sizeof(cmd),
    "curl -s -X POST https://openrouter.ai/api/v1/chat/completions "
    "-H 'Authorization: Bearer %s' "
    "-H 'Content-Type: application/json' "
    "-d @%s",
    key, tmp_payload);

  char* resp = exec_cmd(cmd);
  unlink(tmp_payload);
  return resp;
}

#define BENDER_ANSWER_SYSTEM \
  "You are Bender, an expert AI engineer and systems developer built in Bend2. " \
  "Answer questions accurately and directly based on the context."

static char* call_openrouter_generate(const char* prompt) {
  return call_openrouter_with_system(BENDER_ANSWER_SYSTEM, prompt);
}

static char* extract_choice(const char* json, const char* qid) {
  char needle[128];
  snprintf(needle, sizeof(needle), "\"%s\"", qid);
  const char* p = strstr(json, needle);
  if (!p) return strdup("");
  const char* c = strstr(p, "\"choice\":");
  if (!c) return strdup("");
  c += strlen("\"choice\":");
  while (*c == ' ' || *c == '\"') c++;
  const char* end = c;
  while (*end && *end != '\"' && *end != ',' && *end != '}') end++;
  size_t len = end - c;
  char* r = malloc(len + 1);
  strncpy(r, c, len);
  r[len] = '\0';
  return r;
}

// Unescapes JSON string content into clean, readable text
static char* extract_content(const char* json) {
  if (!json) return strdup("");
  const char* marker = "\"content\":";
  const char* p = strstr(json, marker);
  if (!p) return strdup(json);
  p += strlen(marker);
  while (*p == ' ') p++;
  if (*p != '\"') return strdup("");
  p++; // skip opening quote

  size_t cap = strlen(p) + 1;
  char* out = malloc(cap);
  size_t o = 0;
  int escape = 0;
  for (const char* cur = p; *cur; cur++) {
    if (escape) {
      if (*cur == 'n') out[o++] = '\n';
      else if (*cur == 'r') out[o++] = '\r';
      else if (*cur == 't') out[o++] = '\t';
      else if (*cur == '\"') out[o++] = '\"';
      else if (*cur == '\\') out[o++] = '\\';
      else out[o++] = *cur;
      escape = 0;
    } else if (*cur == '\\') {
      escape = 1;
    } else if (*cur == '\"') {
      break;
    } else {
      out[o++] = *cur;
    }
  }
  out[o] = '\0';
  return out;
}

// Extract field value for compact logging
static double extract_number(const char* json, const char* key) {
  if (!json) return 0.0;
  const char* p = strstr(json, key);
  if (!p) return 0.0;
  p += strlen(key);
  while (*p && (*p == ' ' || *p == ':' || *p == '\"')) p++;
  return strtod(p, NULL);
}

// -----------------------------------------------------------------------------
// Self-improvement loop: Read the code, draft an edit, apply it, verify, repeat
// -----------------------------------------------------------------------------

// Tool output is appended to the state verbatim, so a single large file could
// crowd out everything the agent learned before it. Long output is clipped and
// the clip is announced, keeping the state a readable running transcript.
#define BENDER_MAX_TOOL_OUTPUT 6000

static void state_append(char* state, size_t cap, const char* label, const char* body) {
  size_t used = strlen(state);
  if (used + 64 >= cap) return;
  size_t room = cap - used - 1;
  if (!body) body = "";
  size_t body_len = strlen(body);
  int clipped = 0;
  if (body_len > BENDER_MAX_TOOL_OUTPUT) {
    body_len = BENDER_MAX_TOOL_OUTPUT;
    clipped = 1;
  }
  snprintf(state + used, room, "\n[%s]:\n%.*s%s\n", label,
           (int)body_len, body, clipped ? "\n... (output truncated)" : "");
}

// The command that decides whether an edit was good. run_tests.sh covers the
// file tools, the agent's helpers and the Bend side; BENDER_VERIFY_CMD points
// the loop at a different suite when a goal calls for one.
static const char* verify_command(void) {
  const char* cmd = getenv("BENDER_VERIFY_CMD");
  if (cmd && cmd[0]) return cmd;
  return "./run_tests.sh";
}

// An agent editing its own repository must not wander out of it. Paths are
// taken as relative to the repo root; anything absolute or climbing through
// ".." is refused before it reaches the Edit tool.
static int path_is_in_repo(const char* path) {
  if (!path || !path[0]) return 0;
  if (path[0] == '/' || path[0] == '~') return 0;
  if (strstr(path, "..") != NULL) return 0;
  return 1;
}

// The model answers with sentinel-delimited sections rather than JSON: an edit
// carries exact source text, and sentinels survive quotes, braces and newlines
// that a JSON string would have to escape (and routinely escapes wrongly).
#define EDIT_FORMAT_SYSTEM \
  "You are Bender, an autonomous coding agent improving your own repository.\n" \
  "Reply with EXACTLY this form and nothing else — no prose, no code fences:\n" \
  "<<<PATH>>>\n" \
  "relative/path/from/repo/root\n" \
  "<<<OLD>>>\n" \
  "the exact existing text to replace, copied verbatim including indentation\n" \
  "<<<NEW>>>\n" \
  "the replacement text\n" \
  "<<<END>>>\n" \
  "The OLD block must appear EXACTLY ONCE in the file: include enough " \
  "surrounding lines to make it unique. Leave the OLD block empty only when " \
  "creating a new file. Make one small, self-contained change."

// Returns the text between `open` and the next sentinel, or NULL when the
// section is absent. The caller frees.
static char* slice_section(const char* text, const char* open, const char* close) {
  const char* start = strstr(text, open);
  if (!start) return NULL;
  start += strlen(open);
  if (*start == '\n') start++;
  const char* end = strstr(start, close);
  if (!end) return NULL;
  size_t len = (size_t)(end - start);
  // The newline before the closing sentinel belongs to the delimiter, not to
  // the content it terminates.
  if (len > 0 && start[len - 1] == '\n') len--;
  char* out = malloc(len + 1);
  if (!out) return NULL;
  memcpy(out, start, len);
  out[len] = '\0';
  return out;
}

static void trim_inplace(char* s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ')) {
    s[--len] = '\0';
  }
}

// A model that leaks its reasoning into the answer is the normal case, not the
// exception, so the picker's reply is mined for a path rather than trusted as
// one: the last token that names a file which actually exists wins. Returns a
// malloc'd path, or NULL when the reply contains no usable one.
static char* extract_existing_path(const char* reply) {
  size_t len = strlen(reply);
  char* buf = malloc(len + 1);
  if (!buf) return NULL;

  char* best = NULL;
  size_t i = 0;
  while (i < len) {
    // Tokens are split on whitespace and on the punctuation a sentence leaves
    // around a path ("...read test_tools.c content via..." yields the path).
    while (i < len && (isspace((unsigned char)reply[i]) || strchr("`'\"(),:;", reply[i]))) i++;
    size_t start = i;
    while (i < len && !isspace((unsigned char)reply[i]) && !strchr("`'\"(),:;", reply[i])) i++;
    size_t tok_len = i - start;
    if (tok_len == 0 || tok_len > len) continue;
    memcpy(buf, reply + start, tok_len);
    buf[tok_len] = '\0';
    // Trailing sentence punctuation is not part of the name.
    while (tok_len > 0 && (buf[tok_len - 1] == '.' || buf[tok_len - 1] == '!' ||
                           buf[tok_len - 1] == '?')) {
      buf[--tok_len] = '\0';
    }
    if (tok_len == 0) continue;
    if (!path_is_in_repo(buf) || !bender_exists(buf) || bender_is_dir(buf)) continue;
    free(best);
    best = strdup(buf);
  }
  free(buf);
  return best;
}

// The picker for a search pattern has the same leaked-reasoning problem as the
// one for a path, but a pattern cannot be validated against the filesystem, so
// the last non-empty line is taken and stripped of the quoting a model wraps it
// in. Returns a malloc'd pattern, or NULL when there is nothing usable.
static char* extract_search_pattern(const char* reply) {
  const char* end = reply + strlen(reply);
  while (end > reply && isspace((unsigned char)end[-1])) end--;
  const char* start = end;
  while (start > reply && start[-1] != '\n') start--;

  size_t len = (size_t)(end - start);
  if (len == 0) return NULL;
  char* out = malloc(len + 1);
  if (!out) return NULL;
  memcpy(out, start, len);
  out[len] = '\0';

  // Strip one layer of the quoting a model puts around a literal.
  char* p = out;
  while (*p && strchr("`'\"", *p)) p++;
  size_t plen = strlen(p);
  while (plen > 0 && strchr("`'\".", p[plen - 1])) p[--plen] = '\0';
  if (plen == 0) { free(out); return NULL; }
  memmove(out, p, plen + 1);
  return out;
}

// How far each file has been read, so a repeat request serves the next page
// instead of the same first page again.
#define BENDER_MAX_TRACKED_READS 32
#define BENDER_READ_PAGE 200

typedef struct {
  char path[256];
  long next_line;  // 1-indexed line the next page starts at
  int exhausted;   // the last page ran past the end of the file
} ReadCursor;

static ReadCursor read_cursors[BENDER_MAX_TRACKED_READS];
static int read_cursor_count = 0;

static ReadCursor* read_cursor_for(const char* path) {
  for (int i = 0; i < read_cursor_count; i++) {
    if (strcmp(read_cursors[i].path, path) == 0) return &read_cursors[i];
  }
  if (read_cursor_count >= BENDER_MAX_TRACKED_READS) return NULL;
  ReadCursor* c = &read_cursors[read_cursor_count++];
  snprintf(c->path, sizeof(c->path), "%s", path);
  c->next_line = 1;
  c->exhausted = 0;
  return c;
}

// Describes what has already been read, so the model can ask for the next page
// of a file it has seen part of, or move on from one it has seen all of.
static void describe_reads(char* out, size_t cap) {
  size_t o = 0;
  o += (size_t)snprintf(out + o, cap - o, "Files already read:");
  if (read_cursor_count == 0) {
    snprintf(out + o, cap - o, " none yet.");
    return;
  }
  for (int i = 0; i < read_cursor_count && o + 128 < cap; i++) {
    ReadCursor* c = &read_cursors[i];
    if (c->exhausted) {
      o += (size_t)snprintf(out + o, cap - o,
        "\n- %s: read in full, do not ask for it again.", c->path);
    } else {
      o += (size_t)snprintf(out + o, cap - o,
        "\n- %s: read through line %ld; naming it again serves the next page.",
        c->path, c->next_line - 1);
    }
  }
}

// search_code: ask for a literal string, then grep the repository for it. This
// is how the agent finds the file that matters instead of guessing a name.
static void do_search_code(char* state, size_t cap, const char* goal) {
  char prompt[49152];
  snprintf(prompt, sizeof(prompt),
    "Goal: %s\n\n"
    "Give one literal string to search this repository for — an identifier, a "
    "message, a declaration. Not a regular expression. Reply with the string on "
    "its own and nothing else.\n\nState so far:\n%s", goal, state);
  char* resp = call_openrouter_with_system(
    "You choose one literal search string. Reply with the string alone, nothing else.",
    prompt);
  char* reply = extract_content(resp);
  free(resp);

  char* pattern = extract_search_pattern(reply);
  free(reply);
  if (!pattern) {
    printf("🚫 %sNo search pattern in the reply.%s\n", ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Search failed", "The reply contained no search string.");
    return;
  }

  printf("🔎 %sSearching the repository for '%s'...%s\n", ANSI_MAGENTA, pattern, ANSI_RESET);
  char* hits = tool_grep(pattern, ".");
  char label[512];
  snprintf(label, sizeof(label), "Search for '%s'", pattern);
  state_append(state, cap, label, hits);
  free(hits);
  free(pattern);
}

// read_code: let the model name the file worth reading next, then serve it
// with line numbers. The first read lists the repository instead, so the
// choice is made against what is actually there.
static void do_read_code(char* state, size_t cap, const char* goal, int read_phase) {
  if (read_phase == 0) {
    printf("📖 %sListing repository contents...%s\n", ANSI_MAGENTA, ANSI_RESET);
    char* listing = exec_cmd("ls -1");
    state_append(state, cap, "Repository files", listing);
    free(listing);
    char* readme = tool_read("README.md", 1, 80);
    state_append(state, cap, "README.md (lines 1-80)", readme);
    free(readme);
    return;
  }

  char already[4096];
  describe_reads(already, sizeof(already));

  char prompt[49152];
  snprintf(prompt, sizeof(prompt),
    "Goal: %s\n\n%s\n\n"
    "Name the single file most worth reading next to advance this goal. "
    "Reply with the relative path and nothing else.\n\nState so far:\n%s",
    goal, already, state);
  char* resp = call_openrouter_with_system(
    "You pick one file to read. Reply with a bare relative path, nothing else.",
    prompt);
  char* reply = extract_content(resp);
  free(resp);

  char* path = extract_existing_path(reply);
  if (!path) {
    printf("🚫 %sNo readable file named in the reply.%s\n", ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Read failed",
      "The reply named no file that exists in this repository. Reply with a bare relative path.");
    free(reply);
    return;
  }
  free(reply);

  ReadCursor* cursor = read_cursor_for(path);
  long offset = cursor ? cursor->next_line : 1;

  printf("📖 %sReading '%s' from line %ld...%s\n", ANSI_MAGENTA, path, offset, ANSI_RESET);
  char* content = tool_read(path, offset, BENDER_READ_PAGE);

  // A warning back from Read means the offset ran past the end: the file is
  // done, and saying so is more use to the model than the warning itself.
  int past_end = strncmp(content, "<system-reminder>Warning: the file exists but is shorter", 55) == 0;
  if (past_end && cursor) {
    cursor->exhausted = 1;
    char note[512];
    snprintf(note, sizeof(note), "%s has been read in full; nothing further to read there.", path);
    state_append(state, cap, "Read complete", note);
  } else {
    char label[512];
    snprintf(label, sizeof(label), "%s (from line %ld)", path, offset);
    state_append(state, cap, label, content);
    if (cursor) cursor->next_line = offset + BENDER_READ_PAGE;
  }

  free(content);
  free(path);
}

// apply_edit: draft one edit, apply it with the Edit tool, verify, and roll the
// file back when verification fails. The rollback is what lets the loop keep
// running after a bad patch instead of leaving the repo broken.
static void do_apply_edit(char* state, size_t cap, const char* goal) {
  printf("🛠  %sDrafting an edit via OpenRouter...%s\n", ANSI_MAGENTA, ANSI_RESET);

  char prompt[49152];
  snprintf(prompt, sizeof(prompt), "Goal: %s\n\nState so far:\n%s", goal, state);
  char* resp = call_openrouter_with_system(EDIT_FORMAT_SYSTEM, prompt);
  char* block = extract_content(resp);
  free(resp);

  char* path = slice_section(block, "<<<PATH>>>", "<<<OLD>>>");
  char* old_str = slice_section(block, "<<<OLD>>>", "<<<NEW>>>");
  char* new_str = slice_section(block, "<<<NEW>>>", "<<<END>>>");
  free(block);

  if (!path || !old_str || !new_str) {
    printf("⚠️  %sThe model did not return a well-formed edit block.%s\n", ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Edit failed",
      "The generated edit was not in the required <<<PATH>>>/<<<OLD>>>/<<<NEW>>>/<<<END>>> form.");
    free(path); free(old_str); free(new_str);
    return;
  }
  trim_inplace(path);

  if (!path_is_in_repo(path)) {
    printf("🚫 %sRefusing to edit outside the repository: '%s'%s\n", ANSI_YELLOW, path, ANSI_RESET);
    state_append(state, cap, "Edit refused", "The requested path is outside the repository.");
    free(path); free(old_str); free(new_str);
    return;
  }

  // Snapshot before touching the file: verification decides whether it stays.
  size_t backup_len = 0;
  char* backup = bender_slurp(path, &backup_len);

  printf("✏️  %sEditing '%s'...%s\n", ANSI_MAGENTA, path, ANSI_RESET);
  char* result = tool_edit(path, old_str, new_str, 0);
  printf("   %s\n", result);
  state_append(state, cap, "Edit result", result);
  int applied = strncmp(result, "error:", 6) != 0;
  free(result);
  free(old_str);
  free(new_str);

  if (!applied) {
    free(backup);
    free(path);
    return;
  }

  printf("🔬 %sVerifying: %s%s\n", ANSI_MAGENTA, verify_command(), ANSI_RESET);
  int status = -1;
  char* out = exec_cmd_status(verify_command(), &status);
  if (status == 0) {
    printf("✅ %sVerification passed.%s\n", ANSI_GREEN, ANSI_RESET);
    state_append(state, cap, "Verification passed", out);
  } else {
    printf("❌ %sVerification failed (exit %d) — rolling the file back.%s\n",
           ANSI_YELLOW, status, ANSI_RESET);
    if (backup) {
      char* restore = tool_write(path, backup, backup_len);
      free(restore);
    }
    state_append(state, cap, "Verification failed; edit rolled back", out);
  }
  free(out);
  free(backup);
  free(path);
}

int main(int argc, char** argv) {
  render_banner();

  char state[32768];
  const char* goal_prompt = NULL;
  if (argc > 1 && strlen(argv[1]) > 0) {
    goal_prompt = argv[1];
    snprintf(state, sizeof(state), "User Question/Goal: %s", argv[1]);
  } else {
    goal_prompt = "Inspect the repository, verify hello.bend, and confirm autonomous capabilities are operating.";
    snprintf(state, sizeof(state), "User Question/Goal: %s", goal_prompt);
  }

  printf("%s🎯 [GOAL]%s %s\n\n", ANSI_BOLD, ANSI_RESET, goal_prompt);

  char* final_answer = NULL;
  int read_phase = 0;
  // Read, edit, verify and retry does not fit in the six steps an answer takes.
  // BENDER_MAX_STEPS raises the ceiling for a longer self-improvement run.
  int max_steps = 6;
  const char* steps_env = getenv("BENDER_MAX_STEPS");
  if (steps_env && steps_env[0]) {
    int parsed = atoi(steps_env);
    if (parsed > 0) max_steps = parsed;
  }
  for (int step = 1; step <= max_steps; step++) {
    printf("%s─── Step %d: Jev Classification ──────────────────────────────────────────%s\n", ANSI_CYAN, step, ANSI_RESET);

    // 1. Classify
    char* c_resp = call_typesafe_classify(state);
    char* decision = extract_choice(c_resp, "action");
    double conf = extract_number(c_resp, "\"confidence\":");
    double score = extract_number(c_resp, "\"score\":");
    double noul = extract_number(c_resp, "\"noul\":");

    // Guardrail: Only override generate_answer to read_code if we haven't read any code yet (read_phase == 0).
    // Once code has been read, trust generate_answer and do not trap the agent in an infinite read loop.
    if (strcmp(decision, "generate_answer") == 0 && read_phase == 0 && noul < 0.60) {
      free(decision);
      decision = strdup("read_code");
    }

    // An edit is only drafted against code that has actually been read, so an
    // apply_edit chosen before the first read becomes that read instead.
    if (strcmp(decision, "apply_edit") == 0 && read_phase == 0) {
      free(decision);
      decision = strdup("read_code");
    }

    // Fallback: If we are on the penultimate or final step and still haven't generated an answer, force generate_answer.
    if (step >= max_steps - 1 && final_answer == NULL && strcmp(decision, "task_complete") != 0) {
      free(decision);
      decision = strdup("generate_answer");
    }

    printf("🧠 %sAction Selected:%s %s%-16s%s %s(conf: %.2f, info_prob: %.2f, score: %.2f)%s\n",
      ANSI_BOLD, ANSI_RESET,
      ANSI_YELLOW, decision, ANSI_RESET,
      ANSI_DIM, conf, noul, score, ANSI_RESET);

    // 2. Dispatch
    if (strcmp(decision, "task_complete") == 0) {
      free(c_resp);
      free(decision);
      break;
    } else if (strcmp(decision, "read_code") == 0) {
      do_read_code(state, sizeof(state), goal_prompt, read_phase);
      read_phase++;
    } else if (strcmp(decision, "search_code") == 0) {
      do_search_code(state, sizeof(state), goal_prompt);
    } else if (strcmp(decision, "apply_edit") == 0) {
      do_apply_edit(state, sizeof(state), goal_prompt);
    } else if (strcmp(decision, "run_build") == 0) {
      printf("⚡ %sRunning verification: %s%s\n", ANSI_MAGENTA, verify_command(), ANSI_RESET);
      int status = -1;
      char* out = exec_cmd_status(verify_command(), &status);
      char label[64];
      snprintf(label, sizeof(label), "Verification output (exit %d)", status);
      state_append(state, sizeof(state), label, out);
      free(out);
    } else { // generate_answer
      printf("✨ %sSynthesizing answer via OpenRouter...%s\n", ANSI_MAGENTA, ANSI_RESET);
      char* g_resp = call_openrouter_generate(state);
      if (final_answer) free(final_answer);
      final_answer = extract_content(g_resp);
      state_append(state, sizeof(state), "Answer generated", final_answer);
      free(g_resp);
    }

    free(c_resp);
    free(decision);
  }

  // Final Output Card
  printf("\n%s================================================================================%s\n", ANSI_GREEN, ANSI_RESET);
  printf("%s  ✅ TASK COMPLETE%s\n", ANSI_BOLD, ANSI_RESET);
  printf("%s================================================================================%s\n\n", ANSI_GREEN, ANSI_RESET);

  if (final_answer && strlen(final_answer) > 0) {
    printf("%s%s\n\n", ANSI_RESET, final_answer);
    free(final_answer);
  } else {
    printf("Repository goals verified and all checks passed successfully.\n\n");
  }

  return 0;
}
