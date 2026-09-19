// JSON response extractors for Bendcoder's C FFI.
//
// extract.answer turns one question's object in a TypeSafe System One reply
// into the Answer Data the caller matches on, so no consumer does a positional
// strstr over the raw response. extract.generation lifts the assistant's text
// out of an OpenAI-compatible chat envelope.
//
// Bend inlines this file once but only emits a CID_* for the laws a program
// reaches from main, so each section is guarded on its own id, as in sys_c.c.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef CID_EXTRACT_ANSWER
// -----------------------------------------------------------------------------
// 1. extract_answer: one question's reply as Answer Data
// extract.answer(json: String, qid: String) -> IO(Answer)
// -----------------------------------------------------------------------------

// The span of the response belonging to one question: from its key to where
// the next question's object opens. A missing field cannot read a neighbour's
// answer, which is what an unscoped search did. See #27.
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

static Term answer_missing(Env e, const char* reason) {
  return io_box(e, CID_MISSING, io_str(e, reason, strlen(reason)), 1);
}

// One ParseAnswer per question id, matched on by every consumer: the Answer
// constructors stand for the three question types, and Missing is the case a
// failed request used to smuggle through as "". See #34.
static Term answer_build(Env e, const char* json, const char* qid) {
  if (!json || !*json) {
    return answer_missing(e, "the Classify response was empty");
  }
  const char* bound = NULL;
  const char* p = answer_span(json, qid, &bound);
  if (!p) {
    // A failed request returns an error object holding no answers at all;
    // where it carries a message, that message is the reason. See #32.
    char reason[512];
    char* err = answer_str(json, NULL, "\"error\":");
    if (!err) err = answer_str(json, NULL, "\"message\":");
    if (err) {
      snprintf(reason, sizeof(reason), "Classify failed: %s", err);
      free(err);
    } else {
      snprintf(reason, sizeof(reason), "no answer for \"%s\" in the Classify response", qid);
    }
    return answer_missing(e, reason);
  }
  char* choice = answer_str(p, bound, "\"choice\":");
  if (choice) {
    double conf = 0.0;
    answer_num(p, bound, "\"confidence\":", &conf);
    Term t = io_node(e, CID_CHOSEN,
                     io_str(e, choice, strlen(choice)),
                     f32_rewrap((f32)conf), 1);
    free(choice);
    return t;
  }
  double score = 0.0, conf = 0.0;
  if (answer_num(p, bound, "\"score\":", &score)) {
    answer_num(p, bound, "\"confidence\":", &conf);
    return io_node(e, CID_SCORED, f32_rewrap((f32)score), f32_rewrap((f32)conf), 1);
  }
  double prob = 0.0;
  if (answer_num(p, bound, "\"noul\":", &prob)) {
    // A one-field constructor whose field is a plain 32-bit value is packed
    // into the term itself, not given a heap cell: the generated matcher reads
    // it as `term_loc(x)`, where two-field Scored reads `e.mem[sp+0..1]` and
    // one-field Missing reads `e.mem[sp+0]` because a String cannot pack.
    // io_box here builds a heap node the matcher never looks at, so the loc
    // bits it does read are the pointer, which shows up as a denormal float.
    return term_pak(CID_NOULED, f32_rewrap((f32)prob));
  }
  char reason[512];
  snprintf(reason, sizeof(reason), "unrecognised answer for \"%s\" in the Classify response", qid);
  return answer_missing(e, reason);
}

Term extract_answer_run(Env e, Term* f, IoWork* w) {
  uint64_t j_len = 0, q_len = 0;
  char* json = io_cstr(e, f[0], &j_len);
  char* qid  = io_cstr(e, f[1], &q_len);
  Term out = answer_build(e, json, qid);
  free(json);
  free(qid);
  (void)w;
  return out;
}

static void __attribute__((constructor)) extract_answer_use(void) {
  io_eff(CID_EXTRACT_ANSWER, extract_answer_run, 0);
}
#endif  // CID_EXTRACT_ANSWER

#ifdef CID_EXTRACT_GENERATION
// -----------------------------------------------------------------------------
// 2. extract_generation: assistant content from a chat completion
// extract.generation(json: String) -> IO(String)
// -----------------------------------------------------------------------------

// Extract the assistant content from an OpenAI/OpenRouter chat completion
static char* parse_chat_content(const char* json) {
  if (!json) return strdup("");
  const char* marker = "\"content\":";
  const char* p = strstr(json, marker);
  if (!p) return strdup(json);
  p += strlen(marker);
  while (*p == ' ') p++;
  if (*p != '\"') return strdup("");
  p++; // skip opening quote

  // Unescape until closing unescaped quote
  size_t cap = strlen(p) + 1;
  char* out = malloc(cap);
  size_t o = 0;
  int escape = 0;
  for (const char* cur = p; *cur; cur++) {
    if (escape) {
      if (*cur == 'n') out[o++] = '\n';
      else if (*cur == 'r') out[o++] = '\r';
      else if (*cur == 't') out[o++] = '\t';
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

static Term extract_gen_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term extract_generation_run(Env e, Term* f, IoWork* w) {
  uint64_t j_len = 0;
  char* json = io_cstr(e, f[0], &j_len);
  w->data = parse_chat_content(json);
  w->size = strlen(w->data);
  free(json);
  return extract_gen_pack(e, w);
}

static void __attribute__((constructor)) extract_generation_use(void) {
  io_eff(CID_EXTRACT_GENERATION, extract_generation_run, 0);
}
#endif  // CID_EXTRACT_GENERATION

#ifdef CID_EXTRACT_USAGE
// -----------------------------------------------------------------------------
// 3. extract_usage: total_tokens from a chat completion's usage block
// extract.usage(json: String) -> IO(String)
// -----------------------------------------------------------------------------

// The digits after "total_tokens": — the same positional strstr the rest of
// this file uses, which is fine because a chat envelope carries one usage
// block. "0" when the key is absent, so a provider that omits usage reads as
// free rather than as a parse failure.
static char* parse_usage_tokens(const char* json) {
  long n = 0;
  const char* p = json ? strstr(json, "\"total_tokens\":") : NULL;
  if (p) {
    p += strlen("\"total_tokens\":");
    while (*p == ' ') p++;
    n = strtol(p, NULL, 10);
    if (n < 0) n = 0;
  }
  char* out = malloc(24);
  snprintf(out, 24, "%ld", n);
  return out;
}

static Term extract_usage_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term extract_usage_run(Env e, Term* f, IoWork* w) {
  uint64_t j_len = 0;
  char* json = io_cstr(e, f[0], &j_len);
  w->data = parse_usage_tokens(json);
  w->size = strlen(w->data);
  free(json);
  return extract_usage_pack(e, w);
}

static void __attribute__((constructor)) extract_usage_use(void) {
  io_eff(CID_EXTRACT_USAGE, extract_usage_run, 0);
}
#endif  // CID_EXTRACT_USAGE
