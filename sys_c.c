// Subprocess execution and file I/O primitives for Bend2.
//
// The Read / Write / Edit algorithms live in tools_c.h; this file is only
// the Bend FFI wrapping around them.
//
// The boundary is string-only, matching the other laws in the project: numeric
// arguments (a read's limit, an edit's replace_all flag) arrive as decimal or
// "true"/"false" text and are parsed here, which keeps every law's arguments
// plain strings.
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
#include <sys/wait.h>

#include "tools_c.h"

typedef struct {
  char* data;
  size_t len;
} SysIoBuffer;

#ifdef CID_COMMAND_RUN
// -----------------------------------------------------------------------------
// 1. command_run: execute shell command and capture combined stdout/stderr
// -----------------------------------------------------------------------------
// The exit status travels beside the output in the work item, because the pack
// needs it to choose between Done and Fail and IoWork carries no second slot.
static int command_run_status = 0;

static void command_run_worker(IoWork* w) {
  char* cmd = w->data;
  command_run_status = 0;
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
    command_run_status = 127;  // the shell's "command not found"
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
  int rc = pclose(pipe);
  command_run_status = (rc == -1) ? 127 : WEXITSTATUS(rc);

  if (!buf.data) {
    w->data = strdup("");
    w->size = 0;
  } else {
    w->data = buf.data;
    w->size = buf.len;
  }
}

// Returns Result<&1, &1, U32 & String, String>: Done{output} when the command
// exits 0, Fail{(code, output)} otherwise. This is the shape IO.get_env already
// uses, so a Bend caller matches on it the same way — and it is the whole point
// of the effect, since a verification step that cannot tell a pass from a
// failure cannot decide whether to keep an edit or roll it back.
static Term command_run_pack(Env e, IoWork* w) {
  int status = command_run_status;
  if (status == 0) {
    Term str = io_str(e, w->data, w->size);
    free(w->data);
    return io_done(e, str);
  }
  Term t = io_fail(e, (u32)status, w->data);
  free(w->data);
  return t;
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
// Unnumbered, for feeding a file straight to a model. Read uses sys_read_raw.
// -----------------------------------------------------------------------------
static void sys_read_file_worker(IoWork* w) {
  char* path = w->data;
  size_t len = 0;
  char* content = bendcoder_slurp(path, &len);
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

#ifdef CID_SYS_READ_RAW
// -----------------------------------------------------------------------------
// 3. sys_read_raw: the IO half of Read — checks, size cap, slurp, BOM strip
// sys.read_raw(path: String, limit: String) ->
//   IO(Result<&1, &1, U32 & String, String>)
// Everything downstream of the bytes — the split on '\n', the offset/limit
// selection, the "N\tline" rendering — is pure and lives in tool_read.bend,
// so the worker hands the bytes over: Done{content} on success, Fail{(code,
// message)} for the checked failures, whose message is the same "error: ..."
// text tool_read produced. `limit` only decides whether the 256 KB cap on an
// unbounded read applies.
// -----------------------------------------------------------------------------
typedef struct {
  char* path;
  long  limit;
} ReadRawWorkData;

static void sys_read_raw_worker(IoWork* w) {
  ReadRawWorkData* d = (ReadRawWorkData*)w->data;
  int code = 0;
  size_t len = 0;
  char* result = tool_read_io(d->path, d->limit, &code, &len);
  free(d->path);
  free(d);
  w->code = (u32)code;
  w->data = result;
  w->size = len;
}

static Term sys_read_raw_pack(Env e, IoWork* w) {
  Term t = w->code
    ? io_fail(e, w->code, w->data)
    : io_done(e, io_str(e, w->data, w->size));
  free(w->data);
  return t;
}

Term sys_read_raw_run(Env e, Term* f, IoWork* w) {
  ReadRawWorkData* d = malloc(sizeof(ReadRawWorkData));
  uint64_t l0 = 0, l1 = 0;
  d->path = io_cstr(e, f[0], &l0);
  char* limit_str = io_cstr(e, f[1], &l1);
  d->limit = strtol(limit_str, NULL, 10);
  free(limit_str);
  w->data = (char*)d;
  return io_work(w, sys_read_raw_worker, sys_read_raw_pack);
}

static void __attribute__((constructor)) sys_read_raw_use(void) {
  io_eff(CID_SYS_READ_RAW, sys_read_raw_run, 0);
}
#endif  // CID_SYS_READ_RAW

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

#ifdef CID_SYS_GREP_FILE
// -----------------------------------------------------------------------------
// 6. sys_grep_file: literal search of a file, or of a directory tree
// sys.grep_file(pattern: String, path: String) -> IO(String)
// -----------------------------------------------------------------------------
typedef struct {
  char* pattern;
  char* path;
} GrepWorkData;

static void sys_grep_file_worker(IoWork* w) {
  GrepWorkData* d = (GrepWorkData*)w->data;
  char* result = tool_grep(d->pattern, d->path);
  free(d->pattern);
  free(d->path);
  free(d);
  w->data = result;
  w->size = strlen(result);
}

Term sys_grep_file_run(Env e, Term* f, IoWork* w) {
  GrepWorkData* d = malloc(sizeof(GrepWorkData));
  uint64_t l0 = 0, l1 = 0;
  d->pattern = io_cstr(e, f[0], &l0);
  d->path = io_cstr(e, f[1], &l1);
  w->data = (char*)d;
  return io_work(w, sys_grep_file_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_grep_file_use(void) {
  io_eff(CID_SYS_GREP_FILE, sys_grep_file_run, 0);
}
#endif  // CID_SYS_GREP_FILE

#ifdef CID_SYS_EXISTS
// -----------------------------------------------------------------------------
// 7. sys.file_exists: whether a path exists on disk
// sys.exists(path: String) -> IO(String)
// "true" or "false" over the string-only boundary — the loop's blind-edit
// guard asks it before refusing an edit to a file never read, the way
// bendcoder_agent.c asks bendcoder_exists.
// -----------------------------------------------------------------------------
static void sys_exists_worker(IoWork* w) {
  char* path = w->data;
  int ok = bendcoder_exists(path);
  free(path);
  w->data = strdup(ok ? "true" : "false");
  w->size = strlen(w->data);
}

Term sys_exists_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, sys_exists_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_exists_use(void) {
  io_eff(CID_SYS_EXISTS, sys_exists_run, 0);
}
#endif  // CID_SYS_EXISTS

#ifdef CID_SYS_REMOVE_FILE
// -----------------------------------------------------------------------------
// 8. sys.remove_file: delete a file — deletion is the one file effect
// sys.remove_file(path: String) -> IO(String)
// WriteFile cannot express. The loop keeps failed drafts in place rather
// than reverting (#42), so nothing calls this today; it stays in the tool
// surface for the same reason sys.exists does.
// -----------------------------------------------------------------------------
static void sys_remove_file_worker(IoWork* w) {
  char* path = w->data;
  int ok = (unlink(path) == 0);
  free(path);
  w->data = strdup(ok
    ? "removed"
    : "error: the file could not be removed");
  w->size = strlen(w->data);
}

Term sys_remove_file_run(Env e, Term* f, IoWork* w) {
  w->data = io_cstr(e, f[0], &w->size);
  return io_work(w, sys_remove_file_worker, sys_tool_pack);
}

static void __attribute__((constructor)) sys_remove_file_use(void) {
  io_eff(CID_SYS_REMOVE_FILE, sys_remove_file_run, 0);
}
#endif  // CID_SYS_REMOVE_FILE
