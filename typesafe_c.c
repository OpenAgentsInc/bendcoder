// HTTP POST helper for Bend2 using curl
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  char* data;
  size_t len;
} HttpRespBuffer;

static void typesafe_call_worker(IoWork* w) {
  // Read API key from environment variable TYPESAFE_API_KEY or .env.typesafe
  const char* env_key = getenv("TYPESAFE_API_KEY");
  char file_key[256] = {0};
  const char* key = env_key;

  if (!key || strlen(key) == 0) {
    FILE* kf = fopen(".env.typesafe", "r");
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

  if (!key || strlen(key) == 0 || strcmp(key, "YOUR_TYPESAFE_API_KEY") == 0) {
    const char* err_msg = "{\"error\": \"Missing API key. Please set TYPESAFE_API_KEY in .env.typesafe or environment.\"}";
    w->data = strdup(err_msg);
    w->size = strlen(err_msg);
    return;
  }

  // Write payload to temporary file
  char tmp_payload[] = "/tmp/typesafe_req_XXXXXX";
  int fd = mkstemp(tmp_payload);
  if (fd < 0) {
    w->data = strdup("{\"error\":\"Failed to create temp request file\"}");
    w->size = strlen(w->data);
    return;
  }
  FILE* pf = fdopen(fd, "w");
  if (pf) {
    fputs(w->data, pf);
    fclose(pf);
  } else {
    close(fd);
  }
  free(w->data);

  // Use curl with the payload file
  char cmd[1024];
  snprintf(cmd, sizeof(cmd),
    "curl -s -X POST https://api.typesafe.ai/v1/systemone "
    "-H \"Authorization: Bearer %s\" "
    "-H \"Content-Type: application/json\" "
    "-d @%s",
    key, tmp_payload);

  FILE* pipe = popen(cmd, "r");

  HttpRespBuffer resp = {NULL, 0};
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

static Term typesafe_post_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term typesafe_post_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, typesafe_call_worker, typesafe_post_pack);
}

static void __attribute__((constructor)) typesafe_post_use(void) {
  io_eff(CID_TYPESAFE_POST, typesafe_post_run, 0);
}
