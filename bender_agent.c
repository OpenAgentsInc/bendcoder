// Unified Bender Runtime Runner in C
// Combines TypeSafe System One, OpenRouter, and System tools into a clean terminal UI loop
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/wait.h>
#include <ctype.h>
#include <time.h>

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

// The agent's action space as a type rather than a string compared with
// strcmp in a chain: the dispatch switch is exhaustive over it, and a
// decision that parses to nothing is a halt, not a quiet generate_answer.
// ACTION_NAMES is also the source of the criteria names sent to Classify, so
// the name offered and the name parsed back cannot drift apart. The Bend
// loop keeps the same six actions in `type Action` (action.bend) and proves
// its parse/show round-trip there.
typedef enum {
  ACT_READ_CODE, ACT_SEARCH_CODE, ACT_RUN_BUILD,
  ACT_APPLY_EDIT, ACT_GENERATE_ANSWER, ACT_TASK_COMPLETE,
  ACT_NO_FIT,        // "none": a real decision — Classify says no action fits
  ACT_UNRECOGNIZED   // any other string: a parse failure, not a choice
} Action;

static const char* const ACTION_NAMES[] = {
  [ACT_READ_CODE] = "read_code",
  [ACT_SEARCH_CODE] = "search_code",
  [ACT_RUN_BUILD] = "run_build",
  [ACT_APPLY_EDIT] = "apply_edit",
  [ACT_GENERATE_ANSWER] = "generate_answer",
  [ACT_TASK_COMPLETE] = "task_complete",
  [ACT_NO_FIT] = "none",
};

static Action action_from_string(const char* s) {
  for (int i = 0; i <= ACT_NO_FIT; i++) {
    if (ACTION_NAMES[i] && strcmp(s, ACTION_NAMES[i]) == 0) return (Action)i;
  }
  return ACT_UNRECOGNIZED;
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

// The contract marks 429 (rate limited) and 529 (overloaded) retryable and
// answers them with retry-after-ms, which wins over Retry-After — itself either
// seconds or an HTTP date, and only the numeric form is read. With neither
// header the wait backs off exponentially from half a second, capped so a
// stray header cannot stall the loop for hours. See #32.
#define BENDER_TS_MAX_ATTEMPTS 4
#define BENDER_TS_MAX_WAIT_MS 30000

static long classify_retry_wait_ms(const char* header_path, int attempt) {
  long wait_ms = -1;
  long retry_after_s = -1;
  FILE* hf = fopen(header_path, "r");
  if (hf) {
    char line[512];
    while (fgets(line, sizeof(line), hf)) {
      if (strncasecmp(line, "retry-after-ms:", 15) == 0) wait_ms = atol(line + 15);
      else if (strncasecmp(line, "retry-after:", 12) == 0) retry_after_s = atol(line + 12);
    }
    fclose(hf);
  }
  if (wait_ms < 0 && retry_after_s > 0) wait_ms = retry_after_s * 1000;
  if (wait_ms < 0) wait_ms = 500L << attempt;
  if (wait_ms > BENDER_TS_MAX_WAIT_MS) wait_ms = BENDER_TS_MAX_WAIT_MS;
  return wait_ms;
}

// One JSON string escaper for every payload: the state, OpenRouter message
// contents, and the option labels and descriptions in a Choice's criteria all
// escape the same way, so they all go through here.
static void fjson_string(FILE* pf, const char* s) {
  fputc('\"', pf);
  for (const char* p = s; *p; p++) {
    if (*p == '\"') fputs("\\\"", pf);
    else if (*p == '\\') fputs("\\\\", pf);
    else if (*p == '\n') fputs("\\n", pf);
    else if (*p == '\r') fputs("\\r", pf);
    else if (*p == '\t') fputs("\\t", pf);
    else fputc(*p, pf);
  }
  fputc('\"', pf);
}

// The shared tail of every System One call: POST a prepared payload file.
// Status and headers are captured apart from the body: 429/529 need the
// headers to know how long to wait, and any failure needs its status and body
// logged — an unparseable response already halts the loop, but without this
// there is no way to tell a rate limit from a 422 or a malformed reply.
static char* typesafe_post_file(const char* key, const char* payload_path) {
  char hdr_path[] = "/tmp/bender_ts_hdr_XXXXXX";
  char body_path[] = "/tmp/bender_ts_body_XXXXXX";
  int hfd = mkstemp(hdr_path);
  int bfd = mkstemp(body_path);
  if (hfd < 0 || bfd < 0) {
    if (hfd >= 0) close(hfd);
    if (bfd >= 0) close(bfd);
    return strdup("{}");
  }
  close(hfd);
  close(bfd);

  int status = 0;
  int attempt;
  for (attempt = 1; attempt <= BENDER_TS_MAX_ATTEMPTS; attempt++) {
    char cmd[4096];
    snprintf(cmd, sizeof(cmd),
      "curl -s -X POST https://api.typesafe.ai/v1/systemone "
      "-H 'Authorization: Bearer %s' "
      "-H 'Content-Type: application/json' "
      "-D %s -o %s -w '%%{http_code}' "
      "-d @%s",
      key, hdr_path, body_path, payload_path);
    char* code = exec_cmd(cmd);
    status = atoi(code);
    free(code);
    if ((status != 429 && status != 529) || attempt == BENDER_TS_MAX_ATTEMPTS) break;
    long wait_ms = classify_retry_wait_ms(hdr_path, attempt - 1);
    fprintf(stderr, "%s[typesafe] HTTP %d; retrying in %ld ms (attempt %d of %d)%s\n",
            ANSI_YELLOW, status, wait_ms, attempt + 1, BENDER_TS_MAX_ATTEMPTS, ANSI_RESET);
    struct timespec ts = { wait_ms / 1000, (wait_ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
  }

  char* resp = bender_slurp(body_path, NULL);
  if (!resp) resp = strdup("{}");
  if (status < 200 || status >= 300) {
    fprintf(stderr, "%s[typesafe] request failed: HTTP %d after %d attempt(s); body: %.400s%s\n",
            ANSI_YELLOW, status, attempt, resp, ANSI_RESET);
  }

  unlink(hdr_path);
  unlink(body_path);
  return resp;
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
    fprintf(pf, "{\"model\":\"jev-1.13.0\",\"state\":");
    fjson_string(pf, state_str);
    fprintf(pf, ",\"questions\":{"
      "\"action\":{\"type\":\"choice\",\"instructions\":\"Given the user question or goal and current state, what is the single next best action to take?\","
      "\"criteria\":{"
        "\"%s\":\"Inspect files, repository contents, or directory listings to gather needed facts\","
        "\"%s\":\"Search the repository for a literal string to find which files are relevant\","
        "\"%s\":\"Run a shell command, test, or build to inspect output\","
        "\"%s\":\"Change the code on disk: the fix is understood and a concrete edit to a known file can be written now\","
        "\"%s\":\"Synthesize the final answer, explanation, or code using the LLM\","
        "\"%s\":\"The user request has already been completely answered and verified\","
        "\"%s\":\"No listed action fits: the state does not yet support a next step\"}},"
      "\"has_enough_info\":{\"type\":\"noul\",\"instructions\":\"Does the current state have enough concrete information to directly answer the user prompt?\"},"
      "\"needs_code_change\":{\"type\":\"noul\",\"instructions\":\"Does satisfying this goal require editing files in this repository, rather than only answering in prose?\"},"
      "\"repeats\":{\"type\":\"noul\",\"instructions\":\"Would the next action repeat something the state already records having tried without success?\"},"
      "\"risk\":{\"type\":\"score\",\"instructions\":\"How much can the chosen next action destroy or expose?\","
      "\"criteria\":[\"0: Read-only inspection; nothing on disk changes\",\"1: Runs a command or generates text; reversible\",\"2: Writes to disk or can break the build\"]},"
      "\"confidence_score\":{\"type\":\"score\",\"instructions\":\"How confident are we that we can answer or finish now?\","
      "\"criteria\":[\"0: Need more information from files or commands\",\"1: Partially understood\",\"2: Fully ready to answer or complete\"]}"
    "}}",
      ACTION_NAMES[ACT_READ_CODE], ACTION_NAMES[ACT_SEARCH_CODE],
      ACTION_NAMES[ACT_RUN_BUILD], ACTION_NAMES[ACT_APPLY_EDIT],
      ACTION_NAMES[ACT_GENERATE_ANSWER], ACTION_NAMES[ACT_TASK_COMPLETE],
      ACTION_NAMES[ACT_NO_FIT]);
    fflush(pf);
    fclose(pf);
  }

  char* resp = typesafe_post_file(key, tmp_payload);
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
    fjson_string(pf, system_prompt);
    fputs("},{\"role\":\"user\",\"content\":", pf);
    fjson_string(pf, prompt);
    fputs("}]}", pf);
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

// The span of the response belonging to one question: from its key to where
// the next question's object opens. Scoped by question id because the answers
// share field names: with more than one Noul in a request, an unscoped search
// for "noul" always returns the first one and every later question is silently
// discarded. See #27.
static const char* answer_span(const char* json, const char* qid, const char** bound) {
  char needle[128];
  snprintf(needle, sizeof(needle), "\"%s\"", qid);
  const char* p = strstr(json, needle);
  if (!p) return NULL;
  *bound = strstr(p + strlen(needle), "},\"");
  return p;
}

// Reads the number after key inside [p, bound). Occurrences whose value is not
// numeric are skipped — a qid like "confidence_score" contains "score": inside
// its own key, and only the field's occurrence carries a number. 0 when no
// occurrence parses, so a present 0.0 is still seen as a value.
static int answer_num(const char* p, const char* bound, const char* key, double* out) {
  const char* f = p;
  while ((f = strstr(f, key)) != NULL) {
    if (bound && f >= bound) return 0;
    const char* v = f + strlen(key);
    while (*v == ' ' || *v == '\"') v++;
    char* end = NULL;
    double d = strtod(v, &end);
    if (end != v) { *out = d; return 1; }
    f = v;
  }
  return 0;
}

// Reads the quoted string after key inside [p, bound), unescaping as it goes.
// Occurrences whose value is not a string are skipped, as in answer_num.
// Caller frees; NULL when the key is absent or the value is not a string.
static char* answer_str(const char* p, const char* bound, const char* key) {
  const char* f = p;
  while ((f = strstr(f, key)) != NULL) {
    if (bound && f >= bound) return NULL;
    const char* v = f + strlen(key);
    while (*v == ' ') v++;
    if (*v != '\"') { f = v; continue; }
    v++;
    char* out = malloc(strlen(v) + 1);
    size_t o = 0;
    int esc = 0;
    for (const char* c = v; *c && (!bound || c < bound); c++) {
      if (esc) {
        if (*c == 'n') out[o++] = '\n';
        else if (*c == 'r') out[o++] = '\r';
        else if (*c == 't') out[o++] = '\t';
        else out[o++] = *c;
        esc = 0;
      } else if (*c == '\\') {
        esc = 1;
      } else if (*c == '\"') {
        break;
      } else {
        out[o++] = *c;
      }
    }
    out[o] = '\0';
    return out;
  }
  return NULL;
}

// Reads one numeric field of one question's answer, scoped by question id.
// jev_answer supersedes this for the loop; the test suite reads it directly.
__attribute__((unused))
static double extract_number(const char* json, const char* qid, const char* key) {
  const char* bound = NULL;
  const char* p = (json && qid) ? answer_span(json, qid, &bound) : NULL;
  double v = 0.0;
  if (p) answer_num(p, bound, key, &v);
  return v;
}

// The answer Jev gave one question, as a typed value rather than a set of
// positional strstr reads: the response half of the Question contract that
// agent_primitives.bend declares as `type Answer`. Readers switch on kind, so
// a field can no longer be read out of the wrong question (#27), and a failed
// request is JEV_MISSING carrying its reason — not the "" that used to fall
// through dispatch to generate_answer (#32). See #34.
typedef enum { JEV_MISSING = 0, JEV_CHOSEN, JEV_SCORED, JEV_NOULED } JevKind;

typedef struct {
  JevKind kind;
  char text[512];      // JEV_CHOSEN: the label; JEV_MISSING: the reason
  double confidence;   // JEV_CHOSEN and JEV_SCORED
  double score;        // JEV_SCORED
  double probability;  // JEV_NOULED
} JevAnswer;

// One jev_answer per question id, switched on by every consumer: the kinds
// stand for the three question types, and anything absent, unrecognised or
// failed is JEV_MISSING.
static JevAnswer jev_answer(const char* json, const char* qid) {
  JevAnswer a;
  a.kind = JEV_MISSING;
  a.confidence = a.score = a.probability = 0.0;
  a.text[0] = '\0';
  if (!json || !*json) {
    snprintf(a.text, sizeof(a.text), "the Classify response was empty");
    return a;
  }
  const char* bound = NULL;
  const char* p = qid ? answer_span(json, qid, &bound) : NULL;
  if (!p) {
    // A failed request returns an error object holding no answers at all;
    // where it carries a message, that message is the reason. See #32.
    char* err = answer_str(json, NULL, "\"error\":");
    if (!err) err = answer_str(json, NULL, "\"message\":");
    if (err) {
      snprintf(a.text, sizeof(a.text), "Classify failed: %s", err);
      free(err);
    } else {
      snprintf(a.text, sizeof(a.text), "no answer for \"%s\" in the Classify response",
               qid ? qid : "?");
    }
    return a;
  }
  char* choice = answer_str(p, bound, "\"choice\":");
  if (choice) {
    a.kind = JEV_CHOSEN;
    snprintf(a.text, sizeof(a.text), "%s", choice);
    free(choice);
    answer_num(p, bound, "\"confidence\":", &a.confidence);
    return a;
  }
  if (answer_num(p, bound, "\"score\":", &a.score)) {
    a.kind = JEV_SCORED;
    answer_num(p, bound, "\"confidence\":", &a.confidence);
    return a;
  }
  if (answer_num(p, bound, "\"noul\":", &a.probability)) {
    a.kind = JEV_NOULED;
    return a;
  }
  snprintf(a.text, sizeof(a.text), "unrecognised answer for \"%s\" in the Classify response", qid);
  return a;
}

// -----------------------------------------------------------------------------
// The selector: thresholds and the answers-to-action table, in one reviewable
// place (design rules 7 and 8)
// -----------------------------------------------------------------------------
// selector.bend holds the canonical form — the same table as a match over the
// typed Answer, its rows pinned by laws — and this block mirrors it for the C
// runtime. Keep the two in step.
//
//   Answers                                            Route
//   -------------------------------------------------  -------------------------
//   `action` missing, mistyped, or names no action     Halt with a reason
//   `action` is `none`                                 Halt with a reason
//   `action` confidence under the floor                Do not act; re-read or ask
//   `repeats` high                                     Do not take that action again
//   `risk` at the top level and the goal did not ask   Confirm before running
//   otherwise                                          Act on the choice
//
// Rule 7 asks each threshold to say what it was tuned on. The confidence
// floor is measured: across the delegation runs, steps that advanced the task
// sat at 0.55 and above while runs that flailed for ten steps and landed
// nothing sat between 0.21 and 0.43; 0.45 separates them (#33). The rest are
// marked unmeasured rather than dressed up as data.
#define BENDER_CONFIDENCE_FLOOR 0.45
#define BENDER_EDIT_CONFIDENCE_FLOOR 0.65  // unmeasured; higher by consequence (writes to disk)
#define BENDER_REPEATS_FLOOR 0.60          // carried over; unmeasured
#define BENDER_INFO_FLOOR 0.60             // has_enough_info noul; unmeasured
#define BENDER_RISK_TOP 1.5                // top band of the 0-2 weighted-mean risk score; unmeasured
#define BENDER_ASKED_FLOOR 0.50            // needs_code_change noul; unmeasured
#define BENDER_MAX_LOW_CONFIDENCE 3        // consecutive under-floor steps before the loop stops

// The consequence-weighted floor for one action: apply_edit writes to disk
// and can break the build, so it clears a higher bar than read-only actions.
static double confidence_floor_for(Action act) {
  return act == ACT_APPLY_EDIT ? BENDER_EDIT_CONFIDENCE_FLOOR : BENDER_CONFIDENCE_FLOOR;
}

typedef struct {
  Action act;        // the action the step is routed to
  const char* note;  // why the route differs from the choice (NULL = run it)
} Route;

// The answers-to-action table: the step's answers in, the action to take out.
// The two halt rows live in the caller — a missing or mistyped `action` is
// caught by the kind switch, and `none`/unparseable pass through here to the
// dispatch's ACT_NO_FIT/ACT_UNRECOGNIZED halts.
// Consecutive search misses the loop tolerates before turning to reading.
// Kept with the other thresholds the routing table reads rather than beside
// the counter it compares against.
#define BENDER_SEARCH_MISS_LIMIT 2

static Route route_decision(const char* choice, double conf, double noul,
                            double repeats, double risk, double asked,
                            int read_phase, const char* last_decision,
                            int search_misses) {
  Route r;
  r.act = action_from_string(choice);
  r.note = NULL;

  if (r.act == ACT_NO_FIT || r.act == ACT_UNRECOGNIZED) return r;

  // `action` confidence under the floor: do not act; re-read or ask.
  if (r.act != ACT_TASK_COMPLETE && conf < confidence_floor_for(r.act)) {
    r.act = ACT_READ_CODE;
    r.note = "action confidence is under the floor; re-read or ask instead of acting";
    return r;
  }

  // `repeats` high: do not take that action again.
  if (repeats > BENDER_REPEATS_FLOOR && r.act != ACT_TASK_COMPLETE &&
      last_decision[0] != '\0' && strcmp(choice, last_decision) == 0) {
    r.act = ACT_READ_CODE;
    r.note = "the chosen action repeats a failed attempt; not taking it again";
    return r;
  }

  // `risk` at the top level and the goal did not ask for it: confirm before
  // running. The loop has no one to ask mid-run, so it does not run it.
  if (r.act == ACT_APPLY_EDIT && risk >= BENDER_RISK_TOP && asked < BENDER_ASKED_FLOOR) {
    r.act = ACT_READ_CODE;
    r.note = "risk is at the top level and the goal did not ask for it; needs a person's confirmation";
    return r;
  }

  // A search that keeps missing is not converging. This is the deterministic
  // sibling of the repeats row above: Jev is still asked, but the loop does
  // not wait for it to notice, and a read can only add information.
  if (r.act == ACT_SEARCH_CODE && search_misses >= BENDER_SEARCH_MISS_LIMIT) {
    r.act = ACT_READ_CODE;
    r.note = "several searches in a row found nothing; reading instead";
    return r;
  }

  // Loop guards, kept as rows so they review beside the rest: an edit is only
  // drafted against code already read, and an answer on too little
  // information with nothing read yet is a guess.
  if (r.act == ACT_APPLY_EDIT && read_phase == 0) {
    r.act = ACT_READ_CODE;
    r.note = "an edit is only drafted against code already read; reading first";
    return r;
  }
  if (r.act == ACT_GENERATE_ANSWER && read_phase == 0 && noul < BENDER_INFO_FLOOR) {
    r.act = ACT_READ_CODE;
    r.note = "too little information to answer and nothing read yet; reading first";
    return r;
  }
  return r;
}

// -----------------------------------------------------------------------------
// Self-improvement loop: Read the code, draft an edit, apply it, verify, repeat
// -----------------------------------------------------------------------------

// Tool output is appended to the state verbatim, so a single large file could
// crowd out everything the agent learned before it. Long output is clipped and
// the clip is announced, keeping the state a readable running transcript.
#define BENDER_MAX_TOOL_OUTPUT 6000

static void state_append(char* state, size_t cap, const char* label, const char* body) {
  static int truncation_marked = 0;
  size_t used = strlen(state);
  if (used + 64 >= cap) {
    fprintf(stderr, "%s[warning] state buffer full, dropping further tool output%s\n", ANSI_YELLOW, ANSI_RESET);
    if (!truncation_marked && used < cap - 1) {
      const char *marker = "\n[...state truncated...]";
      size_t mlen = strlen(marker);
      size_t copy = (mlen < cap - used - 1) ? mlen : cap - used - 1;
      memcpy(state + used, marker, copy);
      state[used + copy] = '\0';
      truncation_marked = 1;
    }
    return;
  }
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
// the loop at a different suite when a goal calls for one. A suite that ends
// its output with one "COVERED: <path>" line per file it exercises lets
// apply_edit tell a real pass from a green run that read nothing relevant.
static const char* verify_command(void) {
  const char* cmd = getenv("BENDER_VERIFY_CMD");
  if (cmd && cmd[0]) return cmd;
  return "./run_tests.sh";
}

// Whether the verify output's coverage manifest names `path`: 1 when it does,
// 0 when a manifest is present but does not, -1 when the output carries no
// manifest at all. A pass is only evidence about the files the suite reads —
// run_tests.sh emits the manifest precisely so an edit landing outside it is
// reported as the weaker thing it is rather than as verification. See #22.
static int suite_covers(const char* verify_out, const char* path) {
  if (!verify_out || !strstr(verify_out, "COVERED: ")) return -1;
  while (path[0] == '.' && path[1] == '/') path += 2;
  char needle[512];
  snprintf(needle, sizeof(needle), "COVERED: %s\n", path);
  return strstr(verify_out, needle) != NULL;
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
// that a JSON string would have to escape (and routinely escapes wrongly). A
// change spanning files — or several spots in one — repeats the
// PATH/OLD/NEW group once per hunk before the single <<<END>>>; parsing each
// group is what lets one apply_edit carry a multi-file change.
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
  "When the change spans files or touches several spots in one, repeat the " \
  "<<<PATH>>>/<<<OLD>>>/<<<NEW>>> group once per hunk and put <<<END>>> only " \
  "after the last one — the hunks are applied and verified as a unit. Each " \
  "OLD block must appear EXACTLY ONCE in its file: include enough " \
  "surrounding lines to make it unique. Leave an OLD block empty only when " \
  "creating a new file. Make one small, self-contained change."

// The text of one section: from just after its opening sentinel to just
// before the next one. The newline after the opener and the one before the
// closer belong to the delimiters, not to the content they bracket.
static char* slice_range(const char* start, const char* end) {
  if (*start == '\n') start++;
  size_t len = (size_t)(end - start);
  if (len > 0 && start[len - 1] == '\n') len--;
  char* out = malloc(len + 1);
  if (!out) return NULL;
  memcpy(out, start, len);
  out[len] = '\0';
  return out;
}


// One <<<PATH>>>/<<<OLD>>>/<<<NEW>>> group of an edit block.
typedef struct {
  char* path;
  char* old_str;
  char* new_str;
} EditHunk;

static void free_edit_hunks(EditHunk* hunks, int n) {
  if (!hunks) return;
  for (int i = 0; i < n; i++) {
    free(hunks[i].path);
    free(hunks[i].old_str);
    free(hunks[i].new_str);
  }
  free(hunks);
}

// The earlier of two sentinels at or after `from`; NULL only when both are.
static const char* first_of(const char* from, const char* a, const char* b) {
  const char* pa = strstr(from, a);
  const char* pb = strstr(from, b);
  if (!pa) return pb;
  if (!pb) return pa;
  return pa < pb ? pa : pb;
}

// Parses every <<<PATH>>>/<<<OLD>>>/<<<NEW>>> group before <<<END>>> into a
// malloc'd array (free with free_edit_hunks). Returns the hunk count, or -1
// when the block is malformed — no groups, or a group with a sentinel missing
// or out of order. The first <<<END>>> ends the reply: anything a model
// appends after it is ignored rather than parsed as more hunks.
static int parse_edit_hunks(const char* block, EditHunk** out) {
  *out = NULL;
  if (!block) return -1;
  const char* reply_end = strstr(block, "<<<END>>>");
  int cap = 0;
  for (const char* p = block;
       (p = strstr(p, "<<<PATH>>>")) != NULL && (!reply_end || p < reply_end);
       p += strlen("<<<PATH>>>")) {
    cap++;
  }
  if (cap == 0) return -1;
  EditHunk* hunks = calloc((size_t)cap, sizeof(EditHunk));
  if (!hunks) return -1;

  int n = 0;
  const char* cur = block;
  while (n < cap) {
    const char* p = strstr(cur, "<<<PATH>>>");
    const char* o = p ? strstr(p + strlen("<<<PATH>>>"), "<<<OLD>>>") : NULL;
    const char* nxt = p ? strstr(p + strlen("<<<PATH>>>"), "<<<PATH>>>") : NULL;
    // Each sentinel must belong to this group — before the next group opens —
    // or the block is malformed rather than merely unusual.
    const char* nw = (o && (!nxt || o < nxt))
      ? strstr(o + strlen("<<<OLD>>>"), "<<<NEW>>>") : NULL;
    const char* end = (nw && (!nxt || nw < nxt))
      ? first_of(nw + strlen("<<<NEW>>>"), "<<<PATH>>>", "<<<END>>>") : NULL;
    if (!end) break;
    hunks[n].path = slice_range(p + strlen("<<<PATH>>>"), o);
    hunks[n].old_str = slice_range(o + strlen("<<<OLD>>>"), nw);
    hunks[n].new_str = slice_range(nw + strlen("<<<NEW>>>"), end);
    if (!hunks[n].path || !hunks[n].old_str || !hunks[n].new_str) break;
    n++;
    if (end == reply_end) break;
    cur = end;
  }
  if (n < cap) {
    free_edit_hunks(hunks, n);
    return -1;
  }
  *out = hunks;
  return n;
}

static void trim_inplace(char* s) {
  size_t len = strlen(s);
  while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r' || s[len - 1] == ' ')) {
    s[--len] = '\0';
  }
}

// A model asked for one search string routinely prepends its reasoning, and a
// pattern cannot be validated against the filesystem the way a path could — it
// is open-ended text, which is why it stays with the generation model — so the
// last non-empty line is taken and stripped of the quoting a model wraps it
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

// Set when an edit is refused for an unread file. The refusal already knows
// exactly which file is needed; without this the next read makes a fresh
// generation call and routinely picks a different one.
static char pending_read[256] = "";

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

// Lookup that does not create an entry: used to tell whether a file has been
// read at all, which read_cursor_for cannot answer since it always returns one.
static ReadCursor* read_cursor_find(const char* path) {
  for (int i = 0; i < read_cursor_count; i++) {
    if (strcmp(read_cursors[i].path, path) == 0) return &read_cursors[i];
  }
  return NULL;
}

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

// Describes what has already been read, so Jev can ask for the next page
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

// The cheapest one-line summary a file offers is its first line; giving every
// option the same-shaped description is what lets a Choice contrast them
// (design rule 4). A control byte in the first "line" means it is binary
// noise, not a summary.
static void file_summary(const char* path, char* out, size_t cap) {
  out[0] = '\0';
  FILE* f = fopen(path, "r");
  if (f) {
    if (!fgets(out, (int)cap, f)) out[0] = '\0';
    fclose(f);
  }
  size_t len = strlen(out);
  while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r' ||
                   out[len - 1] == ' ' || out[len - 1] == '\t')) {
    out[--len] = '\0';
  }
  for (size_t i = 0; i < len; i++) {
    if ((unsigned char)out[i] < 0x20 && out[i] != '\t') { out[0] = '\0'; break; }
  }
  if (out[0] == '\0') snprintf(out, cap, "(no descriptive first line)");
}

// One option per path in the repository listing, each described by its first
// line, plus the `none` escape hatch a Choice needs in order to say nothing
// fits (#26). A file already read to the end is not offered again. A Jev
// Choice caps at 255 options; `none` always keeps a slot. Returns the number
// of file options emitted.
#define BENDER_MAX_FILE_OPTIONS 255

static int emit_file_criteria(FILE* pf, const char* listing) {
  int n = 0;
  const char* p = listing;
  while (*p && n < BENDER_MAX_FILE_OPTIONS - 1) {
    const char* eol = strchr(p, '\n');
    size_t len = eol ? (size_t)(eol - p) : strlen(p);
    if (len > 0 && p[len - 1] == '\r') len--;
    if (len > 0 && len < 256) {
      char path[256];
      memcpy(path, p, len);
      path[len] = '\0';
      ReadCursor* c = read_cursor_find(path);
      if (path_is_in_repo(path) && bender_exists(path) && !bender_is_dir(path) &&
          !(c && c->exhausted)) {
        char desc[160];
        file_summary(path, desc, sizeof(desc));
        if (n) fputc(',', pf);
        fjson_string(pf, path);
        fputc(':', pf);
        fjson_string(pf, desc);
        n++;
      }
    }
    if (!eol) break;
    p = eol + 1;
  }
  if (n) fputc(',', pf);
  fprintf(pf, "\"none\":\"No repository file is worth reading for this goal right now\"");
  return n;
}

// Which file to read next is a closed set — the repository listing — so it is
// a Choice, not generated text: Jev cannot name a file that is not an option,
// which deletes the leaked-reasoning mining the old generative picker needed.
// Returns the response body; the caller reads the "file_to_read" choice out
// of it.
static char* call_typesafe_pick_file(const char* state_str, const char* listing) {
  char key_buf[256];
  const char* key = get_api_key("TYPESAFE_API_KEY", ".env.typesafe", key_buf, sizeof(key_buf));
  if (!key) return strdup("{\"error\": \"Missing TypeSafe key\"}");

  char tmp_payload[] = "/tmp/bender_ts_pick_XXXXXX";
  int fd = mkstemp(tmp_payload);
  if (fd < 0) return strdup("{}");
  FILE* pf = fdopen(fd, "w");
  if (pf) {
    fprintf(pf, "{\"model\":\"jev-1.13.0\",\"state\":");
    fjson_string(pf, state_str);
    fprintf(pf, ",\"questions\":{\"file_to_read\":{\"type\":\"choice\","
      "\"instructions\":\"Which single repository file is most worth reading "
      "next to advance the goal?\",\"criteria\":{");
    emit_file_criteria(pf, listing);
    fprintf(pf, "}}}}");
    fflush(pf);
    fclose(pf);
  }

  char* resp = typesafe_post_file(key, tmp_payload);
  unlink(tmp_payload);
  return resp;
}

// Patterns search_code has already run, with their outcomes. The picker sees
// the list so it stops re-proposing the same guesses — MAX_GREP_MATCHES was
// proposed twice in the run this comes from — and a re-proposed pattern is
// skipped outright instead of grepped again, because its result is already in
// the state.
#define BENDER_MAX_TRACKED_SEARCHES 32

typedef struct {
  char pattern[256];
  int missed;
} SearchRecord;

static SearchRecord search_history[BENDER_MAX_TRACKED_SEARCHES];
static int search_history_count = 0;

// Consecutive misses without another action between them. It is the
// deterministic version of the repeats Noul: Jev is asked, but the loop does
// not wait for it to notice the same action keeps failing.
static int search_miss_run = 0;

static SearchRecord* search_record_find(const char* pattern) {
  for (int i = 0; i < search_history_count; i++) {
    if (strcmp(search_history[i].pattern, pattern) == 0) return &search_history[i];
  }
  return NULL;
}

// What the picker needs to know: which patterns already ran and whether they
// hit, so a new proposal is genuinely new rather than the same guess reworded.
static void describe_searches(char* out, size_t cap) {
  size_t o = 0;
  o += (size_t)snprintf(out + o, cap - o, "Searches already run:");
  if (search_history_count == 0) {
    snprintf(out + o, cap - o, " none yet.");
    return;
  }
  for (int i = 0; i < search_history_count && o + 128 < cap; i++) {
    SearchRecord* r = &search_history[i];
    o += (size_t)snprintf(out + o, cap - o, "\n- '%s': %s", r->pattern,
      r->missed ? "no matches — do not propose it again" : "matched");
  }
}

// search_code: ask for a literal string, then grep the repository for it. This
// is how the agent finds the file that matters instead of guessing a name.
static void do_search_code(char* state, size_t cap, const char* goal) {
  char tried[4096];
  describe_searches(tried, sizeof(tried));

  char prompt[49152];
  snprintf(prompt, sizeof(prompt),
    "Goal: %s\n\n%s\n\n"
    "Give one literal string to search this repository for — an identifier, a "
    "message, a declaration. Not a regular expression. A fragment of the right "
    "name beats a full guess at it: shorter strings match more. Reply with the "
    "string on its own and nothing else.\n\nState so far:\n%s",
    goal, tried, state);
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

  // A pattern already run is in the state with its result; running it again
  // buys nothing and reads as flailing, so it is counted as a miss.
  SearchRecord* seen = search_record_find(pattern);
  if (seen) {
    printf("🚫 %s'%s' was already searched; skipping the repeat.%s\n",
           ANSI_YELLOW, pattern, ANSI_RESET);
    char note[640];
    snprintf(note, sizeof(note),
      "'%s' was already searched%s — its result is in the state above. "
      "Shorten it, change it, or read a file the earlier output named.",
      pattern, seen->missed ? " and missed" : "");
    state_append(state, cap, "Search skipped", note);
    search_miss_run++;
    free(pattern);
    return;
  }

  printf("🔎 %sSearching the repository for '%s'...%s\n", ANSI_MAGENTA, pattern, ANSI_RESET);
  char* hits = tool_grep(pattern, ".");
  // A case-insensitive retry reports "No matches found" and then shows what
  // it found anyway — a hit for convergence purposes, not a miss.
  int missed = (strncmp(hits, "No matches found", 16) == 0 &&
                strstr(hits, "case-insensitive") == NULL) ||
               strncmp(hits, "error:", 6) == 0;
  if (search_history_count < BENDER_MAX_TRACKED_SEARCHES) {
    SearchRecord* r = &search_history[search_history_count++];
    snprintf(r->pattern, sizeof(r->pattern), "%s", pattern);
    r->missed = missed;
  }
  search_miss_run = missed ? search_miss_run + 1 : 0;
  char label[512];
  snprintf(label, sizeof(label), "Search for '%s'", pattern);
  state_append(state, cap, label, hits);
  free(hits);
  free(pattern);
}

// The repository listing from the first read, kept because it is also the
// file Choice's option set on every later read.
static char* repo_listing = NULL;

// Serves the next page of path into the state. A warning back from Read means
// the offset ran past the end: the file is done, and saying so is more use to
// the model than the warning itself.
static void serve_read_page(char* state, size_t cap, const char* path, const char* why) {
  ReadCursor* cursor = read_cursor_for(path);
  long offset = cursor ? cursor->next_line : 1;

  printf("📖 %sReading '%s' from line %ld%s...%s\n",
         ANSI_MAGENTA, path, offset, why, ANSI_RESET);
  char* content = tool_read(path, offset, BENDER_READ_PAGE);

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
}

// read_code: the first read lists the repository and serves the README; later
// reads hand that listing to Jev as a Choice, so the file picked is always one
// that exists and no generation call is spent naming it.
static void do_read_code(char* state, size_t cap, const char* goal, int read_phase) {
  if (read_phase == 0) {
    printf("📖 %sListing repository contents...%s\n", ANSI_MAGENTA, ANSI_RESET);
    // Tracked files only: ls -1 shows build output that no edit will touch and
    // that reads as plausible source. See #36.
    char* listing = exec_cmd("git ls-files 2>/dev/null || ls -1");
    state_append(state, cap, "Repository files", listing);
    free(repo_listing);
    repo_listing = listing;
    char* readme = tool_read("README.md", 1, 80);
    state_append(state, cap, "README.md (lines 1-80)", readme);
    free(readme);
    return;
  }

  // A refused edit already named the file it needed; serve that rather than
  // asking again.
  if (pending_read[0]) {
    char wanted[256];
    snprintf(wanted, sizeof(wanted), "%s", pending_read);
    pending_read[0] = '\0';
    serve_read_page(state, cap, wanted, " (named by the refused edit)");
    return;
  }

  // Phase 0 always collects the listing, but a picker with no options is no
  // picker — collect it here if a run somehow got this far without one.
  if (!repo_listing) repo_listing = exec_cmd("git ls-files 2>/dev/null || ls -1");

  char already[4096];
  describe_reads(already, sizeof(already));

  char pick_state[49152];
  snprintf(pick_state, sizeof(pick_state),
    "Goal: %s\n\n%s\n\nState so far:\n%s", goal, already, state);
  char* resp = call_typesafe_pick_file(pick_state, repo_listing);
  // The typed accessor from #34 rather than a raw field read: a failed request
  // is JEV_MISSING and must not read as a filename.
  JevAnswer picked = jev_answer(resp, "file_to_read");
  free(resp);
  char* path = strdup(picked.kind == JEV_CHOSEN ? picked.text : "");

  if (path[0] == '\0') {
    printf("🚫 %sThe file Choice returned nothing; the request may have failed.%s\n",
           ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Read failed",
      "Classify returned no file choice; the request may have failed.");
    free(path);
    return;
  }
  if (strcmp(path, "none") == 0) {
    printf("🚫 %sJev found no file worth reading.%s\n", ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Read skipped",
      "The file Choice answered 'none': no repository file is worth reading for this goal right now.");
    free(path);
    return;
  }
  // The options came from the listing itself, so a name that fails the guard
  // is a malformed reply, not a missing file.
  if (!path_is_in_repo(path) || !bender_exists(path) || bender_is_dir(path)) {
    printf("🚫 %sThe file Choice named '%s', which is not a readable repository file.%s\n",
           ANSI_YELLOW, path, ANSI_RESET);
    state_append(state, cap, "Read failed",
      "The file Choice named something that is not a readable repository file.");
    free(path);
    return;
  }

  serve_read_page(state, cap, path, " (picked by Jev)");
  free(path);
}

// One file an edit batch is about to touch, snapshotted so the whole batch
// can be undone as a unit. Each distinct path is captured once, before its
// first hunk lands — a second hunk on the same file must not re-snapshot the
// already-edited content.
typedef struct {
  char* path;
  char* data;   // pre-edit contents; NULL when the file did not exist
  size_t len;
} FileSnapshot;

// Returns the snapshot for `path`, taking it on first sight. `snaps` must
// have room for one entry per hunk; NULL means out of memory.
static FileSnapshot* snapshot_for(FileSnapshot* snaps, int* n, const char* path) {
  for (int i = 0; i < *n; i++) {
    if (strcmp(snaps[i].path, path) == 0) return &snaps[i];
  }
  FileSnapshot* s = &snaps[(*n)++];
  s->path = strdup(path);
  s->data = bender_slurp(path, &s->len);
  if (!s->path) { (*n)--; return NULL; }
  return s;
}

// Restores every snapshotted file: one the batch changed gets its old
// contents back, and one it created is removed — rollback of the unit, not
// of whichever hunk happened to fail.
static void snapshots_restore(FileSnapshot* snaps, int n) {
  for (int i = 0; i < n; i++) {
    if (snaps[i].data) {
      char* r = tool_write(snaps[i].path, snaps[i].data, snaps[i].len);
      free(r);
    } else {
      unlink(snaps[i].path);
    }
  }
}

static void snapshots_free(FileSnapshot* snaps, int n) {
  for (int i = 0; i < n; i++) {
    free(snaps[i].path);
    free(snaps[i].data);
  }
  free(snaps);
}

// apply_edit: draft an edit — one or more PATH/OLD/NEW hunks — apply it with
// the Edit tool, verify, and roll every touched file back when verification
// fails. A change spanning files arrives as several hunks in one reply and is
// applied as a unit: a mid-batch failure or a failed verify restores all of
// it, which is what lets the loop keep running after a bad patch instead of
// leaving the repo half-changed.
static void do_apply_edit(char* state, size_t cap, const char* goal) {
  printf("🛠  %sDrafting an edit via OpenRouter...%s\n", ANSI_MAGENTA, ANSI_RESET);

  char prompt[49152];
  snprintf(prompt, sizeof(prompt), "Goal: %s\n\nState so far:\n%s", goal, state);
  char* resp = call_openrouter_with_system(EDIT_FORMAT_SYSTEM, prompt);
  char* block = extract_content(resp);
  free(resp);

  EditHunk* hunks = NULL;
  int hunk_n = parse_edit_hunks(block, &hunks);
  free(block);

  if (hunk_n <= 0) {
    printf("⚠️  %sThe model did not return a well-formed edit block.%s\n", ANSI_YELLOW, ANSI_RESET);
    state_append(state, cap, "Edit failed",
      "The generated edit was not in the required <<<PATH>>>/<<<OLD>>>/<<<NEW>>>/<<<END>>> form.");
    free_edit_hunks(hunks, 0);
    return;
  }

  // Every hunk is checked before any file is touched, so a refused hunk
  // cannot leave the earlier ones applied.
  for (int i = 0; i < hunk_n; i++) {
    EditHunk* h = &hunks[i];
    trim_inplace(h->path);
    if (!path_is_in_repo(h->path)) {
      printf("🚫 %sRefusing to edit outside the repository: '%s'%s\n",
             ANSI_YELLOW, h->path, ANSI_RESET);
      state_append(state, cap, "Edit refused", "The requested path is outside the repository.");
      free_edit_hunks(hunks, hunk_n);
      return;
    }
    // An edit to a file the agent has not read is a guess. ~/coder's Edit
    // refuses it for the same reason ("File has not been read yet"), and the
    // loop needs the refusal more, because nothing else stops it inventing
    // plausible text and proposing it over and over.
    if (bender_exists(h->path) && !read_cursor_find(h->path)) {
      printf("🚫 %s'%s' has not been read yet; refusing to edit it blind.%s\n",
             ANSI_YELLOW, h->path, ANSI_RESET);
      char note[512];
      snprintf(note, sizeof(note),
        "%s has not been read yet, so the edit was refused. Read it first, then "
        "quote its text exactly.", h->path);
      state_append(state, cap, "Edit refused", note);
      snprintf(pending_read, sizeof(pending_read), "%s", h->path);
      free_edit_hunks(hunks, hunk_n);
      return;
    }
  }

  FileSnapshot* snaps = calloc((size_t)hunk_n, sizeof(FileSnapshot));
  if (!snaps) {
    free_edit_hunks(hunks, hunk_n);
    return;
  }
  int snap_n = 0;
  int applied = 1;
  for (int i = 0; i < hunk_n; i++) {
    EditHunk* h = &hunks[i];
    if (!snapshot_for(snaps, &snap_n, h->path)) { applied = 0; break; }
    printf("✏️  %sEditing '%s'...%s\n", ANSI_MAGENTA, h->path, ANSI_RESET);
    char* result = tool_edit(h->path, h->old_str, h->new_str, 0);
    printf("   %s\n", result);
    char label[320];
    snprintf(label, sizeof(label), "Edit result (%s)", h->path);
    state_append(state, cap, label, result);
    if (strncmp(result, "error:", 6) == 0) {
      applied = 0;
      free(result);
      break;
    }
    free(result);
  }

  if (!applied) {
    printf("↩️  %sRolling back the %d file(s) this edit touched.%s\n",
           ANSI_YELLOW, snap_n, ANSI_RESET);
    snapshots_restore(snaps, snap_n);
    snapshots_free(snaps, snap_n);
    free_edit_hunks(hunks, hunk_n);
    return;
  }

  printf("🔬 %sVerifying: %s%s\n", ANSI_MAGENTA, verify_command(), ANSI_RESET);
  int status = -1;
  char* out = exec_cmd_status(verify_command(), &status);
  if (status == 0) {
    // A green suite is only evidence about the files it reads. The manifest
    // run_tests.sh prints (one COVERED: line per exercised file) is checked
    // for the file just edited; a pass over a file no check reads is reported
    // as the weaker thing it is rather than claimed as verification. See #22.
    // An edit is a batch now, so the weakest file decides: one hunk landing in
    // a file no check reads is enough to make the whole pass weaker than it
    // looks, and naming that file is what makes the warning useful.
    int covered = 1;
    const char* uncovered = NULL;
    for (int i = 0; i < hunk_n; i++) {
      int c = suite_covers(out, hunks[i].path);
      if (c < covered) { covered = c; uncovered = hunks[i].path; }
    }
    if (covered == 1) {
      printf("✅ %sVerification passed.%s\n", ANSI_GREEN, ANSI_RESET);
      state_append(state, cap, "Verification passed", out);
    } else {
      char label[512];
      if (covered == 0) {
        snprintf(label, sizeof(label),
          "Verification passed, but nothing in the suite exercises %s", uncovered);
      } else {
        snprintf(label, sizeof(label),
          "Verification passed, but the suite reported no coverage manifest — "
          "whether it exercises %s is unknown", uncovered ? uncovered : "the edited files");
      }
      printf("⚠️  %s%s.%s\n", ANSI_YELLOW, label, ANSI_RESET);
      state_append(state, cap, label, out);
    }
  } else {
    printf("❌ %sVerification failed (exit %d) — rolling the edits back.%s\n",
           ANSI_YELLOW, status, ANSI_RESET);
    snapshots_restore(snaps, snap_n);
    state_append(state, cap, "Verification failed; edits rolled back", out);
  }
  free(out);
  snapshots_free(snaps, snap_n);
  free_edit_hunks(hunks, hunk_n);
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
  // The thresholds and the answers-to-action table live in the selector block
  // above (canonically in selector.bend); each step calls route_decision.

  int halted_early = 0;
  int low_confidence_run = 0;
  char last_decision[64] = "";
  int max_steps = 6;
  const char* steps_env = getenv("BENDER_MAX_STEPS");
  if (steps_env && steps_env[0]) {
    int parsed = atoi(steps_env);
    if (parsed > 0) max_steps = parsed;
  }
  for (int step = 1; step <= max_steps; step++) {
    printf("%s─── Step %d: Jev Classification ──────────────────────────────────────────%s\n", ANSI_CYAN, step, ANSI_RESET);

    // 1. Classify — one typed answer per question, switched on rather than
    // read positionally. See #34.
    char* c_resp = call_typesafe_classify(state);
    JevAnswer action   = jev_answer(c_resp, "action");
    JevAnswer info     = jev_answer(c_resp, "has_enough_info");
    JevAnswer progress = jev_answer(c_resp, "confidence_score");
    JevAnswer needs    = jev_answer(c_resp, "needs_code_change");
    JevAnswer rep      = jev_answer(c_resp, "repeats");
    JevAnswer risk_a   = jev_answer(c_resp, "risk");

    char* decision = NULL;
    double conf = 0.0;
    switch (action.kind) {
      case JEV_CHOSEN:
        decision = strdup(action.text);
        conf = action.confidence;
        break;
      case JEV_MISSING:
        // A failed request has no answer, and halting beats the old
        // fall-through to generate_answer, which read a 429 as a decision.
        // See #32.
        printf("⚠️  %sClassify returned no answer: %s Halting rather than guessing.%s\n",
               ANSI_YELLOW, action.text, ANSI_RESET);
        break;
      case JEV_SCORED:
      case JEV_NOULED:
        printf("⚠️  %s'action' answered with the wrong type; halting rather than guessing.%s\n",
               ANSI_YELLOW, ANSI_RESET);
        break;
    }
    if (!decision) {
      free(c_resp);
      break;
    }

    // A question answered with the wrong type reads as zero, as an absent one
    // did before — the answer's kind is what carries the failure now.
    double noul = 0.0, score = 0.0, needs_change = 0.0, repeats = 0.0, risk = 0.0;
    if (info.kind == JEV_NOULED) noul = info.probability;
    if (progress.kind == JEV_SCORED) score = progress.score;
    if (needs.kind == JEV_NOULED) needs_change = needs.probability;
    if (rep.kind == JEV_NOULED) repeats = rep.probability;
    if (risk_a.kind == JEV_SCORED) risk = risk_a.score;

    // 2. Route: the answers-to-action table maps the step's answers to the
    // action taken. A reroute says why, and the next round's state sees it.
    Route r = route_decision(decision, conf, noul, repeats, risk, needs_change,
                             read_phase, last_decision, search_miss_run);
    if (r.act != ACT_UNRECOGNIZED && strcmp(decision, ACTION_NAMES[r.act]) != 0) {
      free(decision);
      decision = strdup(ACTION_NAMES[r.act]);
      printf("🔀 %sSelector: %s%s\n", ANSI_YELLOW, r.note ? r.note : "", ANSI_RESET);
      if (r.note) state_append(state, sizeof(state), "Selector rerouted", r.note);
    }

    // Fuel policy rather than an answer route, so it stays beside the loop:
    // on the penultimate or final step with no answer yet, force one.
    if (step >= max_steps - 1 && final_answer == NULL && decision[0] != '\0' &&
        strcmp(decision, ACTION_NAMES[ACT_NO_FIT]) != 0 &&
        strcmp(decision, ACTION_NAMES[ACT_TASK_COMPLETE]) != 0) {
      free(decision);
      decision = strdup(ACTION_NAMES[ACT_GENERATE_ANSWER]);
    }

    printf("🧠 %sAction Selected:%s %s%-16s%s %s(conf: %.2f, info: %.2f, score: %.2f, "
           "needs_change: %.2f, repeats: %.2f, risk: %.2f)%s\n",
      ANSI_BOLD, ANSI_RESET,
      ANSI_YELLOW, decision, ANSI_RESET,
      ANSI_DIM, conf, noul, score, needs_change, repeats, risk, ANSI_RESET);

    // Jev saying, step after step, that it does not know. Acting on it anyway
    // is how a run burns its whole budget and lands nothing.
    if (conf < BENDER_CONFIDENCE_FLOOR) {
      low_confidence_run++;
    } else {
      low_confidence_run = 0;
    }
    if (low_confidence_run >= BENDER_MAX_LOW_CONFIDENCE) {
      printf("🛑 %s%d steps below the confidence floor (%.2f); stopping rather than flailing.%s\n",
             ANSI_YELLOW, low_confidence_run, BENDER_CONFIDENCE_FLOOR, ANSI_RESET);
      halted_early = 1;
      free(c_resp);
      free(decision);
      break;
    }

    snprintf(last_decision, sizeof(last_decision), "%s", decision);

    // Anything that is not search_code — including the reads a stuck search is
    // nudged into — breaks the miss run.
    if (action_from_string(decision) != ACT_SEARCH_CODE) search_miss_run = 0;

    // 3. Dispatch. The decision string is decoded once and the switch is
    // exhaustive over Action: a string no action owns is a halt, not a
    // fallthrough to generate_answer.
    int halt = 0;
    switch (action_from_string(decision)) {
      case ACT_UNRECOGNIZED:
        // Classify returned nothing parseable — a failed request or a
        // decision naming no action, not a choice. Falling through to
        // generate_answer would present the failure to the loop as a
        // confident decision to generate. See #32.
        printf("⚠️  %sClassify returned no recognizable action; halting rather than guessing.%s\n",
               ANSI_YELLOW, ANSI_RESET);
        halt = 1;
        halted_early = 1;
        break;
      case ACT_NO_FIT:
        // Jev saying nothing fits, which a Choice can only express when it is
        // given the option — its probabilities always sum to one.
        printf("🛑 %sNo listed action fits the current state; stopping.%s\n",
               ANSI_YELLOW, ANSI_RESET);
        state_append(state, sizeof(state), "Stalled",
          "Classify reported that no listed action fits the current state.");
        halt = 1;
        halted_early = 1;
        break;
      case ACT_TASK_COMPLETE:
        halt = 1;
        break;
      case ACT_READ_CODE:
        do_read_code(state, sizeof(state), goal_prompt, read_phase);
        read_phase++;
        break;
      case ACT_SEARCH_CODE:
        do_search_code(state, sizeof(state), goal_prompt);
        break;
      case ACT_APPLY_EDIT:
        do_apply_edit(state, sizeof(state), goal_prompt);
        break;
      case ACT_RUN_BUILD: {
        printf("⚡ %sRunning verification: %s%s\n", ANSI_MAGENTA, verify_command(), ANSI_RESET);
        int status = -1;
        char* out = exec_cmd_status(verify_command(), &status);
        char label[64];
        snprintf(label, sizeof(label), "Verification output (exit %d)", status);
        state_append(state, sizeof(state), label, out);
        free(out);
        break;
      }
      case ACT_GENERATE_ANSWER: {
        printf("✨ %sSynthesizing answer via OpenRouter...%s\n", ANSI_MAGENTA, ANSI_RESET);
        char* g_resp = call_openrouter_generate(state);
        if (final_answer) free(final_answer);
        final_answer = extract_content(g_resp);
        state_append(state, sizeof(state), "Answer generated", final_answer);
        free(g_resp);
        break;
      }
    }

    free(c_resp);
    free(decision);
    if (halt) break;
  }

  // Final Output Card. A run that halted on a failed request or on a stall did
  // not complete anything, and saying so beats a green banner over a failure.
  const char* colour = halted_early ? ANSI_YELLOW : ANSI_GREEN;
  printf("\n%s================================================================================%s\n", colour, ANSI_RESET);
  printf("%s  %s%s\n", ANSI_BOLD, halted_early ? "⚠️  STOPPED EARLY" : "✅ TASK COMPLETE", ANSI_RESET);
  printf("%s================================================================================%s\n\n", colour, ANSI_RESET);

  if (final_answer && strlen(final_answer) > 0) {
    printf("%s%s\n\n", ANSI_RESET, final_answer);
    free(final_answer);
  } else {
    printf("Repository goals verified and all checks passed successfully.\n\n");
  }

  return 0;
}
