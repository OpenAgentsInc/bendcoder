// HTTP POST helper for Bend2 using curl
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

typedef struct {
  char* data;
  size_t len;
} HttpRespBuffer;

// The contract marks 429 (rate limited) and 529 (overloaded) retryable and
// answers them with retry-after-ms, which wins over Retry-After — itself either
// seconds or an HTTP date, and only the numeric form is read. With neither
// header the wait backs off exponentially from half a second, capped so a
// stray header cannot stall the loop for hours. Same shape as
// classify_retry_wait_ms in bender_agent.c; see #32.
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

  // Status and headers are captured apart from the body: 429/529 need the
  // headers to know how long to wait, and any failure needs its status and
  // body logged — an unparseable response already halts the loop, but without
  // this there is no way to tell a rate limit from a 422 or a malformed reply.
  char hdr_path[] = "/tmp/typesafe_hdr_XXXXXX";
  char body_path[] = "/tmp/typesafe_body_XXXXXX";
  int hfd = mkstemp(hdr_path);
  int bfd = mkstemp(body_path);
  if (hfd < 0 || bfd < 0) {
    if (hfd >= 0) close(hfd);
    if (bfd >= 0) close(bfd);
    unlink(tmp_payload);
    w->data = strdup("{}");
    w->size = 2;
    return;
  }
  close(hfd);
  close(bfd);

  int status = 0;
  int attempt;
  for (attempt = 1; attempt <= BENDER_TS_MAX_ATTEMPTS; attempt++) {
    char cmd[1024];
    snprintf(cmd, sizeof(cmd),
      "curl -s -X POST https://api.typesafe.ai/v1/systemone "
      "-H \"Authorization: Bearer %s\" "
      "-H \"Content-Type: application/json\" "
      "-D %s -o %s -w '%%{http_code}' "
      "-d @%s",
      key, hdr_path, body_path, tmp_payload);

    FILE* pipe = popen(cmd, "r");
    char codebuf[32] = {0};
    if (pipe) {
      size_t got = fread(codebuf, 1, sizeof(codebuf) - 1, pipe);
      codebuf[got] = '\0';
      pclose(pipe);
    }
    status = atoi(codebuf);

    if ((status != 429 && status != 529) || attempt == BENDER_TS_MAX_ATTEMPTS) break;
    long wait_ms = classify_retry_wait_ms(hdr_path, attempt - 1);
    fprintf(stderr, "[typesafe] HTTP %d; retrying in %ld ms (attempt %d of %d)\n",
            status, wait_ms, attempt + 1, BENDER_TS_MAX_ATTEMPTS);
    struct timespec ts = { wait_ms / 1000, (wait_ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
  }

  HttpRespBuffer resp = {NULL, 0};
  char chunk[1024];
  size_t bytes;
  FILE* bf = fopen(body_path, "r");
  if (bf) {
    while ((bytes = fread(chunk, 1, sizeof(chunk), bf)) > 0) {
      char* n = realloc(resp.data, resp.len + bytes + 1);
      if (!n) break;
      resp.data = n;
      memcpy(resp.data + resp.len, chunk, bytes);
      resp.len += bytes;
      resp.data[resp.len] = '\0';
    }
    fclose(bf);
  }

  if (status < 200 || status >= 300) {
    fprintf(stderr, "[typesafe] request failed: HTTP %d after %d attempt(s); body: %.400s\n",
            status, attempt, resp.data ? resp.data : "");
  }

  unlink(hdr_path);
  unlink(body_path);
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
