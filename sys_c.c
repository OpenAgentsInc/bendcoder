// Subprocess execution and file I/O primitives for Bend2
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  char* data;
  size_t len;
} SysIoBuffer;

// -----------------------------------------------------------------------------
// 1. command_run: execute shell command and capture combined stdout/stderr
// -----------------------------------------------------------------------------
static void command_run_worker(IoWork* w) {
  // Command string is in w->data
  char* cmd = w->data;
  if (!cmd || strlen(cmd) == 0) {
    w->data = strdup("");
    w->size = 0;
    return;
  }

  // Redirect stderr to stdout so agent can read build/runtime errors
  char full_cmd[2048];
  snprintf(full_cmd, sizeof(full_cmd), "%s 2>&1", cmd);

  FILE* pipe = popen(full_cmd, "r");
  free(cmd);

  if (!pipe) {
    w->data = strdup("[Error: failed to spawn process]");
    w->size = strlen(w->data);
    return;
  }

  SysIoBuffer buf = {NULL, 0};
  char chunk[1024];
  size_t bytes;
  while ((bytes = fread(chunk, 1, sizeof(chunk), pipe)) > 0) {
    char* n = realloc(buf.data, buf.len + bytes + 1);
    if (!n) break;
    buf.data = n;
    memcpy(buf.data + buf.len, chunk, bytes);
    buf.len += bytes;
    buf.data[buf.len] = '\0';
  }
  pclose(pipe);

  if (!buf.data) {
    w->data = strdup("");
    w->size = 0;
  } else {
    w->data = buf.data;
    w->size = buf.len;
  }
}

static Term command_run_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term command_run_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, command_run_worker, command_run_pack);
}

static void __attribute__((constructor)) command_run_use(void) {
  io_eff(CID_COMMAND_RUN, command_run_run, 0);
}

// -----------------------------------------------------------------------------
// 2. sys_read_file: read full file content into a String
// -----------------------------------------------------------------------------
static void sys_read_file_worker(IoWork* w) {
  char* path = w->data;
  FILE* f = fopen(path, "rb");
  free(path);

  if (!f) {
    w->data = strdup("");
    w->size = 0;
    return;
  }

  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (sz <= 0) {
    fclose(f);
    w->data = strdup("");
    w->size = 0;
    return;
  }

  char* content = malloc(sz + 1);
  if (!content) {
    fclose(f);
    w->data = strdup("");
    w->size = 0;
    return;
  }

  size_t read_bytes = fread(content, 1, sz, f);
  content[read_bytes] = '\0';
  fclose(f);

  w->data = content;
  w->size = read_bytes;
}

static Term sys_read_file_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

Term sys_read_file_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, sys_read_file_worker, sys_read_file_pack);
}

static void __attribute__((constructor)) sys_read_file_use(void) {
  io_eff(CID_SYS_READ_FILE, sys_read_file_run, 0);
}

// -----------------------------------------------------------------------------
// 3. sys_write_file: overwrite file content with string
// -----------------------------------------------------------------------------
typedef struct {
  char* path;
  char* content;
  size_t content_len;
} WriteWorkData;

static void sys_write_file_worker(IoWork* w) {
  WriteWorkData* d = (WriteWorkData*)w->data;
  FILE* f = fopen(d->path, "wb");
  if (f) {
    fwrite(d->content, 1, d->content_len, f);
    fclose(f);
  }
  free(d->path);
  free(d->content);
  free(d);
}

static Term sys_write_file_pack(Env e, IoWork* w) {
  return term_pak(CID_UNIT, 0);
}

Term sys_write_file_run(Env e, Term* f, IoWork* w) {
  WriteWorkData* d = malloc(sizeof(WriteWorkData));
  uint64_t path_len = 0;
  uint64_t cont_len = 0;
  d->path = io_cstr(e, f[0], &path_len);
  d->content = io_cstr(e, f[1], &cont_len);
  d->content_len = cont_len;
  w->data = (char*)d;
  return io_work(w, sys_write_file_worker, sys_write_file_pack);
}

static void __attribute__((constructor)) sys_write_file_use(void) {
  io_eff(CID_SYS_WRITE_FILE, sys_write_file_run, 0);
}
