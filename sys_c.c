// Subprocess execution and file I/O primitives for Bend2.
//
// The Read / Write / Edit algorithms live in tools_c.h, shared with
// bender_agent.c; this file is only the Bend FFI wrapping around them.
//
// The boundary is string-only, matching the other laws in the project: numeric
// arguments (a read's offset and limit, an edit's replace_all flag) arrive as
// decimal or "true"/"false" text and are parsed here, which keeps every law a
// plain `String -> ... -> IO(String)`.
//
// Bend inlines this whole file once but only emits a CID_* for the laws a
// program actually reaches from main, so each section is guarded on its own id.
// Without the guards a program using some of these laws fails to compile on the
// ones it left out.
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>

#include "tools_c.h"

typedef struct {
  char* data;
  size_t len;
} SysIoBuffer;

#ifdef CID_COMMAND_RUN
// -----------------------------------------------------------------------------
// 1. command_run: execute shell command and capture combined stdout/stderr
// -----------------------------------------------------------------------------
static void command_run_worker(IoWork* w) {
  char* cmd = w->data;
  if (!cmd || strlen(cmd) == 0) {
    w->data = strdup("");
    w->size = 0;
    return;
  }

  char full_cmd[4096];
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
#endif  // CID_COMMAND_RUN

// -----------------------------------------------------------------------------
// Shared packing: every tool below returns one heap string.
// -----------------------------------------------------------------------------
__attribute__((unused))
static Term sys_tool_pack(Env e, IoWork* w) {
  Term str = io_str(e, w->data, w->size);
  free(w->data);
  return str;
}

#ifdef CID_SYS_READ_FILE
// -----------------------------------------------------------------------------
// 2. sys_read_file: read full raw file content into a String
// sys.read_file(path: String) -> IO(String)
// Unnumbered, for feeding a file straight to a model. Read uses sys_read_lines.
// -----------------------------------------------------------------------------
static void sys_read_file_worker(IoWork* w) {
  char* path = w->data;
  size_t len = 0;
  char* content = bender_slurp(path, &len);
  free(path);

  if (!content) {
    w->data = strdup("");
    w->size = 0;
    return;
  }
  w->data = content;
  w->size = len;
}

Term sys_read_file_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, sys_read_file_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_read_file_use(void) {
  io_eff(CID_SYS_READ_FILE, sys_read_file_run, 0);
}
#endif  // CID_SYS_READ_FILE

#ifdef CID_SYS_READ_LINES
// -----------------------------------------------------------------------------
// 3. sys_read_lines: 1-indexed numbered read with offset and limit
// sys.read_lines(path: String, offset: String, limit: String) -> IO(String)
// offset "0" or "1" both start at line 1; limit "0" reads to end of file.
// -----------------------------------------------------------------------------
typedef struct {
  char* path;
  long offset;
  long limit;
} ReadLinesWorkData;

static void sys_read_lines_worker(IoWork* w) {
  ReadLinesWorkData* d = (ReadLinesWorkData*)w->data;
  char* result = tool_read(d->path, d->offset, d->limit);
  free(d->path);
  free(d);
  w->data = result;
  w->size = strlen(result);
}

Term sys_read_lines_run(Env e, Term* f, IoWork* w) {
  ReadLinesWorkData* d = malloc(sizeof(ReadLinesWorkData));
  uint64_t l0 = 0, l1 = 0, l2 = 0;
  d->path = io_cstr(e, f[0], &l0);
  char* offset_str = io_cstr(e, f[1], &l1);
  char* limit_str = io_cstr(e, f[2], &l2);
  d->offset = strtol(offset_str, NULL, 10);
  d->limit = strtol(limit_str, NULL, 10);
  free(offset_str);
  free(limit_str);
  w->data = (char*)d;
  return io_work(w, sys_read_lines_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_read_lines_use(void) {
  io_eff(CID_SYS_READ_LINES, sys_read_lines_run, 0);
}
#endif  // CID_SYS_READ_LINES

#ifdef CID_SYS_WRITE_FILE
// -----------------------------------------------------------------------------
// 4. sys_write_file: write / overwrite a file, creating parent directories
// sys.write_file(path: String, content: String) -> IO(String)
// -----------------------------------------------------------------------------
typedef struct {
  char* path;
  char* content;
  size_t content_len;
} WriteWorkData;

static void sys_write_file_worker(IoWork* w) {
  WriteWorkData* d = (WriteWorkData*)w->data;
  char* result = tool_write(d->path, d->content, d->content_len);
  free(d->path);
  free(d->content);
  free(d);
  w->data = result;
  w->size = strlen(result);
}

Term sys_write_file_run(Env e, Term* f, IoWork* w) {
  WriteWorkData* d = malloc(sizeof(WriteWorkData));
  uint64_t path_len = 0;
  uint64_t cont_len = 0;
  d->path = io_cstr(e, f[0], &path_len);
  d->content = io_cstr(e, f[1], &cont_len);
  d->content_len = cont_len;
  w->data = (char*)d;
  return io_work(w, sys_write_file_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_write_file_use(void) {
  io_eff(CID_SYS_WRITE_FILE, sys_write_file_run, 0);
}
#endif  // CID_SYS_WRITE_FILE

#ifdef CID_SYS_EDIT_FILE
// -----------------------------------------------------------------------------
// 5. sys_edit_file: exact-match search and replace
// sys.edit_file(path, old_str, new_str, replace_all: String) -> IO(String)
// replace_all is "true" or "false"; anything else reads as false.
// -----------------------------------------------------------------------------
typedef struct {
  char* path;
  char* old_str;
  char* new_str;
  int replace_all;
} EditWorkData;

static void sys_edit_file_worker(IoWork* w) {
  EditWorkData* d = (EditWorkData*)w->data;
  char* result = tool_edit(d->path, d->old_str, d->new_str, d->replace_all);
  free(d->path);
  free(d->old_str);
  free(d->new_str);
  free(d);
  w->data = result;
  w->size = strlen(result);
}

Term sys_edit_file_run(Env e, Term* f, IoWork* w) {
  EditWorkData* d = malloc(sizeof(EditWorkData));
  uint64_t l0 = 0, l1 = 0, l2 = 0, l3 = 0;
  d->path = io_cstr(e, f[0], &l0);
  d->old_str = io_cstr(e, f[1], &l1);
  d->new_str = io_cstr(e, f[2], &l2);
  char* flag = io_cstr(e, f[3], &l3);
  d->replace_all = (strcmp(flag, "true") == 0);
  free(flag);
  w->data = (char*)d;
  return io_work(w, sys_edit_file_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_edit_file_use(void) {
  io_eff(CID_SYS_EDIT_FILE, sys_edit_file_run, 0);
}
#endif  // CID_SYS_EDIT_FILE
