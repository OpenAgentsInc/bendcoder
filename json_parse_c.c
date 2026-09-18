// Robust JSON and response extractors for Bender C FFI
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Extract the value of "choice": "..." from a TypeSafe response
static char* parse_choice_val(const char* json, const char* qid) {
  if (!json || !qid) return strdup("");
  char needle[256];
  snprintf(needle, sizeof(needle), "\"%s\"", qid);
  const char* p = strstr(json, needle);
  if (!p) return strdup("");

  const char* ch = strstr(p, "\"choice\":");
  if (!ch) return strdup("");
  ch += strlen("\"choice\":");
  while (*ch == ' ' || *ch == '\"') ch++;
  const char* end = ch;
  while (*end && *end != '\"' && *end != ',' && *end != '}') end++;
  size_t len = end - ch;
  char* res = malloc(len + 1);
  strncpy(res, ch, len);
  res[len] = '\0';
  return res;
}

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

// 1. extract_choice(response_json: String, question_id: String) -> IO(String)
static void extract_choice_worker(IoWork* w) {
  // handled in run
}

static Term extract_choice_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term extract_choice_run(Env e, Term* f, IoWork* w) {
  uint64_t j_len = 0;
  uint64_t q_len = 0;
  char* json = io_cstr(e, f[0], &j_len);
  char* qid  = io_cstr(e, f[1], &q_len);
  w->data = parse_choice_val(json, qid);
  w->size = strlen(w->data);
  free(json);
  free(qid);
  return extract_choice_pack(e, w);
}

static void __attribute__((constructor)) extract_choice_use(void) {
  io_eff(CID_EXTRACT_CHOICE, extract_choice_run, 0);
}

// 2. extract_generation(response_json: String) -> IO(String)
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
