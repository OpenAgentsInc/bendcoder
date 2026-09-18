// Read / Write / Edit: the three self-improvement file tools, adapted from
// ~/coder (crates/coder-tools/src/cc/{read,write,edit}.rs) into plain C so the
// Bend FFI layer (sys_c.c) and the agent runtime (bender_agent.c) share one
// implementation instead of each growing its own.
//
// Every entry point returns a malloc'd string the caller frees. Failures come
// back as readable text prefixed with "error: " rather than as a status code,
// because that text is fed straight back into the agent's state for the next
// Classify round.
#ifndef BENDER_TOOLS_C_H
#define BENDER_TOOLS_C_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

// MAX_OUTPUT_SIZE from ~/coder files.rs: the whole-file size a Read refuses
// once no limit narrows it, so a stray read cannot swamp the agent's state.
#define BENDER_MAX_OUTPUT_SIZE (256 * 1024)

// ----------------------------------------------------------------------------
// Shared helpers
// ----------------------------------------------------------------------------

static char* bender_fmt(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

#include <stdarg.h>

// Allocates exactly as much as the formatted message needs, so an error can
// quote an arbitrarily long old_string without being clipped.
static char* bender_fmt(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  va_list ap2;
  va_copy(ap2, ap);
  int n = vsnprintf(NULL, 0, fmt, ap);
  va_end(ap);
  if (n < 0) {
    va_end(ap2);
    return strdup("error: message formatting failed");
  }
  char* out = (char*)malloc((size_t)n + 1);
  if (!out) {
    va_end(ap2);
    return strdup("error: out of memory");
  }
  vsnprintf(out, (size_t)n + 1, fmt, ap2);
  va_end(ap2);
  return out;
}

// Reads the whole file. Returns NULL when it cannot be opened; on success
// *out_len holds the byte count and the buffer is NUL-terminated.
static char* bender_slurp(const char* path, size_t* out_len) {
  FILE* f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz < 0) { fclose(f); return NULL; }
  char* buf = (char*)malloc((size_t)sz + 1);
  if (!buf) { fclose(f); return NULL; }
  size_t r = fread(buf, 1, (size_t)sz, f);
  buf[r] = '\0';
  fclose(f);
  if (out_len) *out_len = r;
  return buf;
}

static int bender_is_dir(const char* path) {
  struct stat st;
  if (stat(path, &st) != 0) return 0;
  return S_ISDIR(st.st_mode);
}

static int bender_exists(const char* path) {
  struct stat st;
  return stat(path, &st) == 0;
}

// `mkdir -p` over the path's parent directories, so Write and Edit can create
// a file in a directory that does not exist yet.
static int bender_mkdir_parents(const char* path) {
  char* copy = strdup(path);
  if (!copy) return -1;
  int rc = 0;
  for (char* p = copy + 1; *p; p++) {
    if (*p != '/') continue;
    *p = '\0';
    if (!bender_exists(copy) && mkdir(copy, 0755) != 0) { rc = -1; }
    *p = '/';
    if (rc != 0) break;
  }
  free(copy);
  return rc;
}

static size_t bender_count_matches(const char* haystack, const char* needle) {
  size_t needle_len = strlen(needle);
  if (needle_len == 0) return 0;
  size_t count = 0;
  const char* p = haystack;
  while ((p = strstr(p, needle)) != NULL) {
    count++;
    p += needle_len;
  }
  return count;
}

// Replaces the first `max` occurrences of `old` with `new` (max == 0 replaces
// every occurrence). *out_len receives the result's byte length so a content
// with embedded NULs still writes back at the right size.
static char* bender_replace(const char* content, size_t content_len,
                            const char* old_str, const char* new_str,
                            size_t max, size_t* out_len) {
  size_t old_len = strlen(old_str);
  size_t new_len = strlen(new_str);
  size_t hits = bender_count_matches(content, old_str);
  if (max > 0 && hits > max) hits = max;

  size_t cap = content_len + hits * new_len + 1;
  if (new_len < old_len) cap = content_len + 1;
  char* out = (char*)malloc(cap);
  if (!out) return NULL;

  size_t o = 0;
  size_t done = 0;
  const char* cur = content;
  const char* end = content + content_len;
  while (cur < end) {
    const char* hit = (max == 0 || done < max) ? strstr(cur, old_str) : NULL;
    if (!hit) {
      size_t tail = (size_t)(end - cur);
      memcpy(out + o, cur, tail);
      o += tail;
      break;
    }
    size_t prefix = (size_t)(hit - cur);
    memcpy(out + o, cur, prefix);
    o += prefix;
    memcpy(out + o, new_str, new_len);
    o += new_len;
    cur = hit + old_len;
    done++;
  }
  out[o] = '\0';
  if (out_len) *out_len = o;
  return out;
}

static char* bender_write_bytes(const char* path, const char* data, size_t len) {
  bender_mkdir_parents(path);
  FILE* f = fopen(path, "wb");
  if (!f) return bender_fmt("error: Failed to open %s for writing", path);
  size_t w = fwrite(data, 1, len, f);
  fclose(f);
  if (w != len) return bender_fmt("error: Short write to %s (%zu of %zu bytes)", path, w, len);
  return NULL;
}

// ----------------------------------------------------------------------------
// Read
// ----------------------------------------------------------------------------
// 1-indexed lines rendered as "N\tline", the format ~/coder's add_line_numbers
// produces, so a line number quoted back by the model addresses the same line.
// `offset` is the first line to emit (0 and 1 both mean line 1); `limit` <= 0
// means "to the end of the file".
static char* tool_read(const char* path, long offset, long limit) {
  if (offset < 1) offset = 1;

  if (bender_is_dir(path)) {
    return bender_fmt("error: EISDIR: illegal operation on a directory, read '%s'", path);
  }

  struct stat st;
  if (stat(path, &st) != 0) {
    return bender_fmt("error: File does not exist: %s", path);
  }
  if (limit <= 0 && st.st_size > BENDER_MAX_OUTPUT_SIZE) {
    return bender_fmt(
      "error: File content (%lld bytes) exceeds maximum allowed size (%d bytes). "
      "Use offset and limit to read specific portions of the file.",
      (long long)st.st_size, BENDER_MAX_OUTPUT_SIZE);
  }

  size_t len = 0;
  char* content = bender_slurp(path, &len);
  if (!content) return bender_fmt("error: Failed to read %s", path);

  // Skip a UTF-8 BOM so it does not land at the head of line 1.
  char* text = content;
  if (len >= 3 && (unsigned char)text[0] == 0xEF &&
      (unsigned char)text[1] == 0xBB && (unsigned char)text[2] == 0xBF) {
    text += 3;
    len -= 3;
  }

  if (len == 0) {
    free(content);
    return strdup("<system-reminder>Warning: the file exists but the contents are empty.</system-reminder>");
  }

  // Split on '\n' the way the source algorithm does: a trailing newline yields
  // a final empty line, so "a\n" counts as two lines.
  long first = offset - 1;
  long last = (limit > 0) ? first + limit : -1;

  size_t cap = len + 64;
  char* out = (char*)malloc(cap);
  if (!out) { free(content); return strdup("error: out of memory"); }
  size_t o = 0;
  long index = 0;
  long emitted = 0;

  char* cur = text;
  char* stop = text + len;
  while (cur <= stop) {
    char* nl = memchr(cur, '\n', (size_t)(stop - cur));
    char* line_end = nl ? nl : stop;
    if (index >= first && (last < 0 || index < last)) {
      size_t line_len = (size_t)(line_end - cur);
      if (line_len > 0 && cur[line_len - 1] == '\r') line_len--;  // CRLF
      // 24 covers the line number, the tab and the newline.
      if (o + line_len + 24 > cap) {
        cap = (o + line_len + 64) * 2;
        char* grown = (char*)realloc(out, cap);
        if (!grown) { free(out); free(content); return strdup("error: out of memory"); }
        out = grown;
      }
      if (emitted > 0) out[o++] = '\n';
      o += (size_t)snprintf(out + o, cap - o, "%ld\t", index + 1);
      memcpy(out + o, cur, line_len);
      o += line_len;
      emitted++;
    }
    index++;
    if (!nl) break;
    cur = nl + 1;
  }
  out[o] = '\0';
  free(content);

  if (emitted == 0) {
    free(out);
    return bender_fmt(
      "<system-reminder>Warning: the file exists but is shorter than the provided offset (%ld). "
      "The file has %ld lines.</system-reminder>", offset, index);
  }
  return out;
}

// ----------------------------------------------------------------------------
// Write
// ----------------------------------------------------------------------------
// Full write / overwrite, creating any missing parent directories.
static char* tool_write(const char* path, const char* content, size_t len) {
  if (bender_is_dir(path)) {
    return bender_fmt("error: EISDIR: illegal operation on a directory, write '%s'", path);
  }
  int existed = bender_exists(path);
  char* err = bender_write_bytes(path, content, len);
  if (err) return err;
  return existed
    ? bender_fmt("The file %s has been updated successfully.", path)
    : bender_fmt("File created successfully at: %s", path);
}

// ----------------------------------------------------------------------------
// Edit
// ----------------------------------------------------------------------------
// Exact-match search and replace. An ambiguous `old_string` is refused rather
// than guessed at: with more than one match and replace_all off, the caller is
// told how many matches there are and asked for more context.
static char* tool_edit(const char* path, const char* old_str, const char* new_str,
                       int replace_all) {
  if (strcmp(old_str, new_str) == 0) {
    return strdup("error: `old_string` and `new_string` are identical; nothing to replace.");
  }

  int existed = bender_exists(path);

  // An empty old_string means "create this file", matching ~/coder's Edit.
  if (old_str[0] == '\0') {
    if (existed) {
      return bender_fmt("error: Cannot create new file - file already exists: %s", path);
    }
    char* err = bender_write_bytes(path, new_str, strlen(new_str));
    if (err) return err;
    return bender_fmt("File created successfully at: %s", path);
  }

  if (!existed) return bender_fmt("error: File does not exist: %s", path);
  if (bender_is_dir(path)) {
    return bender_fmt("error: EISDIR: illegal operation on a directory, edit '%s'", path);
  }

  size_t len = 0;
  char* content = bender_slurp(path, &len);
  if (!content) return bender_fmt("error: Failed to read %s", path);

  size_t matches = bender_count_matches(content, old_str);
  if (matches == 0) {
    char* err = bender_fmt("error: String to replace not found in %s.\nString: %s", path, old_str);
    free(content);
    return err;
  }
  if (matches > 1 && !replace_all) {
    char* err = bender_fmt(
      "error: Found %zu matches of the string to replace in %s, but replace_all is false. "
      "To replace all occurrences set replace_all to true. To replace one occurrence, "
      "provide more context to uniquely identify the instance.\nString: %s",
      matches, path, old_str);
    free(content);
    return err;
  }

  // Deleting a line: when new_string is empty and old_string has no trailing
  // newline, the newline after the match goes with it, so no blank line is left
  // behind.
  char* search = (char*)old_str;
  char* search_owned = NULL;
  size_t old_len = strlen(old_str);
  if (new_str[0] == '\0' && old_len > 0 && old_str[old_len - 1] != '\n') {
    search_owned = (char*)malloc(old_len + 2);
    if (search_owned) {
      memcpy(search_owned, old_str, old_len);
      search_owned[old_len] = '\n';
      search_owned[old_len + 1] = '\0';
      if (strstr(content, search_owned)) {
        search = search_owned;
      } else {
        free(search_owned);
        search_owned = NULL;
      }
    }
  }

  size_t updated_len = 0;
  char* updated = bender_replace(content, len, search, new_str,
                                 replace_all ? 0 : 1, &updated_len);
  free(content);
  free(search_owned);
  if (!updated) return strdup("error: out of memory");

  char* err = bender_write_bytes(path, updated, updated_len);
  free(updated);
  if (err) return err;

  return replace_all
    ? bender_fmt("The file %s has been updated. All %zu occurrences were successfully replaced.", path, matches)
    : bender_fmt("The file %s has been updated successfully.", path);
}

#endif  // BENDER_TOOLS_C_H
