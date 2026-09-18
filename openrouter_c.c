// OpenRouter / OpenAI-compatible chat completion helper for Bend2 using curl
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  char* data;
  size_t len;
} OpenRouterRespBuffer;

// Model routing applied to every OpenRouter request. OpenRouter tries the
// payload's "model" field first, then this "models" list in order.
// OPENROUTER_MODEL and OPENROUTER_BACKUP_MODEL override the defaults.
static const char* openrouter_model(void) {
  const char* m = getenv("OPENROUTER_MODEL");
  return (m && m[0]) ? m : "openai/gpt-oss-120b:nitro";
}

static const char* openrouter_backup_model(void) {
  const char* m = getenv("OPENROUTER_BACKUP_MODEL");
  return (m && m[0]) ? m : "deepseek/deepseek-v4-flash-0731:free";
}

// Insert a "models" fallback list after the payload's opening brace.
static char* openrouter_payload_with_fallback(const char* payload) {
  const char* primary = openrouter_model();
  const char* backup = openrouter_backup_model();
  if (!payload || payload[0] != '{') {
    return strdup(payload ? payload : "{}");
  }
  size_t need = strlen(payload) + strlen(primary) + strlen(backup) + 32;
  char* out = malloc(need);
  if (!out) return strdup(payload);
  snprintf(out, need, "{\"models\":[\"%s\",\"%s\"],%s", primary, backup,
    payload + 1);
  return out;
}

static void openrouter_call_worker(IoWork* w) {
  const char* env_var_name = "OPENROUTER_API_KEY";
  const char* env_key = getenv(env_var_name);
  char file_key[256] = {0};
  const char* key = env_key;

  if (!key || strlen(key) == 0) {
    FILE* kf = fopen(".env.openrouter", "r");
    if (kf) {
      char line[256];
      while (fgets(line, sizeof(line), kf)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char* nl = strchr(line, '\r');
        if (nl) *nl = '\0';
        nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (strlen(line) > 0) {
          strncpy(file_key, line, sizeof(file_key) - 1);
          key = file_key;
          break;
        }
      }
      fclose(kf);
    }
  }

  if (!key || strlen(key) == 0 || strcmp(key, "YOUR_OPENROUTER_API_KEY") == 0) {
    const char* err_msg = "{\"error\": \"Missing OpenRouter API key. Please set OPENROUTER_API_KEY in .env.openrouter or environment.\"}";
    w->data = strdup(err_msg);
    w->size = strlen(err_msg);
    return;
  }

  // Write payload to temporary file
  char tmp_payload[] = "/tmp/openrouter_req_XXXXXX";
  int fd = mkstemp(tmp_payload);
  if (fd < 0) {
    w->data = strdup("{\"error\":\"Failed to create temp request file\"}");
    w->size = strlen(w->data);
    return;
  }
  char* payload = openrouter_payload_with_fallback(w->data);
  FILE* pf = fdopen(fd, "w");
  if (pf) {
    fputs(payload, pf);
    fclose(pf);
  } else {
    close(fd);
  }
  free(payload);
  free(w->data);

  // Use curl with the payload file
  char cmd[1024];
  snprintf(cmd, sizeof(cmd),
    "curl -s -X POST https://openrouter.ai/api/v1/chat/completions "
    "-H 'Authorization: Bearer %s' "
    "-H 'Content-Type: application/json' "
    "-d @%s",
    key, tmp_payload);

  FILE* pipe = popen(cmd, "r");

  OpenRouterRespBuffer resp = {NULL, 0};
  char chunk[1024];
  size_t bytes;
  if (pipe) {
    while ((bytes = fread(chunk, 1, sizeof(chunk), pipe)) > 0) {
      char* n = realloc(resp.data, resp.len + bytes + 1);
      if (!n) break;
      resp.data = n;
      memcpy(resp.data + resp.len, chunk, bytes);
      resp.len += bytes;
      resp.data[resp.len] = '\0';
    }
    pclose(pipe);
  }

  unlink(tmp_payload);

  if (!resp.data) {
    w->data = strdup("{}");
    w->size = 2;
  } else {
    w->data = resp.data;
    w->size = resp.len;
  }
}

static Term openrouter_post_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term openrouter_post_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, openrouter_call_worker, openrouter_post_pack);
}

static void __attribute__((constructor)) openrouter_post_use(void) {
  io_eff(CID_OPENROUTER_POST, openrouter_post_run, 0);
}
