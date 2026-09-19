// Read / Write / Edit: the three self-improvement file tools, adapted from
// ~/coder (crates/coder-tools/src/cc/{read,write,edit}.rs) into plain C so the
// Bend FFI layer (sys_c.c) wraps one implementation — the agent loop itself
// lives in bender_agent.bend.
//
// Every entry point returns a malloc'd string the caller frees. Failures come
// back as readable text prefixed with "error: " rather than as a status code,
// because that text is fed straight back into the agent's state for the next
// Classify round.
#ifndef BENDER_TOOLS_C_H
#define BENDER_TOOLS_C_H

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>

// MAX_OUTPUT_SIZE from ~/coder files.rs: the whole-file size a Read refuses
// once no limit narrows it, so a stray read cannot swamp the agent's state.
#define BENDER_MAX_OUTPUT_SIZE (256 * 1024)

// How much of a line the nearest-match hint shows when an Edit misses.
#define BENDER_NEAREST_MAX_LINE 200

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
// tool_read_io is the IO half of Read — the only part that must live in C.
// The directory and existence checks, the whole-file size cap, the slurp and
// the BOM strip all need the file's size or its bytes. Everything downstream
// (the split on '\n', the offset/limit selection, the "N\tline" rendering) is
// a pure String -> String that lives in tool_read.bend, where its laws are
// proved; tool_read below is that pure half's C mirror, kept so test_tools.c
// can exercise the rendering the Bend half's laws cover. Keep them in step.
//
// Returns a malloc'd buffer. *code is 0 on success and *len the byte count
// after the BOM strip; on failure *code is an errno-style category and the
// buffer holds the "error: " text tool_read reported.
static char* tool_read_io(const char* path, long limit, int* code, size_t* len) {
  if (bender_is_dir(path)) {
    *code = EISDIR;
    char* msg = bender_fmt("error: EISDIR: illegal operation on a directory, read '%s'", path);
    *len = msg ? strlen(msg) : 0;
    return msg;
  }

  struct stat st;
  if (stat(path, &st) != 0) {
    *code = ENOENT;
    char* msg = bender_fmt("error: File does not exist: %s", path);
    *len = msg ? strlen(msg) : 0;
    return msg;
  }
  if (limit <= 0 && st.st_size > BENDER_MAX_OUTPUT_SIZE) {
    *code = EFBIG;
    char* msg = bender_fmt(
      "error: File content (%lld bytes) exceeds maximum allowed size (%d bytes). "
      "Use offset and limit to read specific portions of the file.",
      (long long)st.st_size, BENDER_MAX_OUTPUT_SIZE);
    *len = msg ? strlen(msg) : 0;
    return msg;
  }

  char* content = bender_slurp(path, len);
  if (!content) {
    *code = EIO;
    char* msg = bender_fmt("error: Failed to read %s", path);
    *len = msg ? strlen(msg) : 0;
    return msg;
  }

  // Skip a UTF-8 BOM in place, so the returned buffer stays the allocation
  // and the FFI worker can free it without tracking a second pointer.
  if (*len >= 3 && (unsigned char)content[0] == 0xEF &&
      (unsigned char)content[1] == 0xBB && (unsigned char)content[2] == 0xBF) {
    memmove(content, content + 3, *len - 2);
    *len -= 3;
  }
  *code = 0;
  return content;
}

// The C mirror of render() in tool_read.bend — 1-indexed lines rendered as
// "N\tline", the format ~/coder's add_line_numbers produces, so a line number
// quoted back by the model addresses the same line. `offset` is the first
// line to emit (0 and 1 both mean line 1); `limit` <= 0 means "to the end of
// the file". test_tools.c is its caller; sys_c.c uses tool_read_io.
__attribute__((unused))
static char* tool_read(const char* path, long offset, long limit) {
  if (offset < 1) offset = 1;

  int code = 0;
  size_t len = 0;
  char* text = tool_read_io(path, limit, &code, &len);
  if (code) return text;

  if (len == 0) {
    free(text);
    return strdup("<system-reminder>Warning: the file exists but the contents are empty.</system-reminder>");
  }

  // Split on '\n' the way the source algorithm does: a trailing newline yields
  // a final empty line, so "a\n" counts as two lines.
  long first = offset - 1;
  long last = (limit > 0) ? first + limit : -1;

  size_t cap = len + 64;
  char* out = (char*)malloc(cap);
  if (!out) { free(text); return strdup("error: out of memory"); }
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
        if (!grown) { free(out); free(text); return strdup("error: out of memory"); }
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
  free(text);

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

// A model that has just read a file through Read sees "N\tline" and routinely
// quotes that numbering back when it writes an old_string, dropping the number
// but keeping the tab. Strips a leading line-number prefix from each line so
// such an old_string can still be matched against the file. Only ever used as
// a fallback after the exact string fails, and only kept when it resolves.
static char* bender_strip_line_prefixes(const char* s, int* changed) {
  size_t len = strlen(s);
  char* out = (char*)malloc(len + 1);
  if (!out) return NULL;
  size_t o = 0;
  int any = 0;
  size_t i = 0;
  while (i <= len) {
    // Measure this line.
    size_t line_end = i;
    while (line_end < len && s[line_end] != '\n') line_end++;

    size_t j = i;
    size_t digits = 0;
    while (j < line_end && s[j] >= '0' && s[j] <= '9') { j++; digits++; }
    if (digits > 0 && j < line_end && (s[j] == '\t' || s[j] == ':')) {
      i = j + 1;          // "26\t" or "26:"
      any = 1;
    } else if (i < line_end && s[i] == '\t') {
      i = i + 1;          // the number already dropped, the tab left behind
      any = 1;
    }

    size_t keep = line_end - i;
    memcpy(out + o, s + i, keep);
    o += keep;
    if (line_end < len) out[o++] = '\n';
    i = line_end + 1;
    if (line_end >= len) break;
  }
  out[o] = '\0';
  if (changed) *changed = any;
  return out;
}

// When old_string does not match, "not found" is a dead end: it says what did
// not happen, not what is true, so a model with a wrong idea of the file has
// nothing to correct against and proposes the same text again. This locates the
// longest leading run of old_string that does occur and renders the real lines
// there, turning the failure into a correction signal.
static char* bender_nearest_hint(const char* content, const char* old_str) {
  // Every line of old_string is tried as an anchor, not just the first. When a
  // model fabricates, it usually invents around something real — a made-up
  // comment above a genuine line of code — so the first line is often the least
  // reliable one to search for.
  const char* hit = NULL;
  const char* line = old_str;
  while (*line && !hit) {
    const char* line_nl = strchr(line, '\n');
    const char* line_stop = line_nl ? line_nl : line + strlen(line);

    const char* start = line;
    while (start < line_stop && (*start == ' ' || *start == '\t')) start++;
    size_t line_len = (size_t)(line_stop - start);
    while (line_len > 0 && (start[line_len - 1] == ' ' || start[line_len - 1] == '\r')) line_len--;

    if (line_len >= 8) {
      char* needle = (char*)malloc(line_len + 1);
      if (!needle) return NULL;
      memcpy(needle, start, line_len);
      needle[line_len] = '\0';
      // Shrink from the right, so a line that is nearly right still anchors on
      // the part that is.
      for (size_t len = line_len; len >= 8; len--) {
        needle[len] = '\0';
        hit = strstr(content, needle);
        if (hit) break;
      }
      free(needle);
    }

    if (!line_nl) break;
    line = line_nl + 1;
  }
  if (!hit) return NULL;

  // Which line is it on, and what do the next few lines actually say?
  long line_no = 1;
  for (const char* p = content; p < hit; p++) {
    if (*p == '\n') line_no++;
  }
  const char* line_start = hit;
  while (line_start > content && line_start[-1] != '\n') line_start--;

  // Four lines, each clipped, is all the context that is useful here, so a
  // fixed buffer is enough and keeps this independent of the Grep section.
  char out[4 * (BENDER_NEAREST_MAX_LINE + 24)];
  size_t o = 0;
  const char* p = line_start;
  for (int i = 0; i < 4 && *p && o < sizeof(out) - 1; i++) {
    const char* e = strchr(p, '\n');
    size_t l = e ? (size_t)(e - p) : strlen(p);
    if (l > BENDER_NEAREST_MAX_LINE) l = BENDER_NEAREST_MAX_LINE;
    int n = snprintf(out + o, sizeof(out) - o, "%ld:%.*s\n", line_no + i, (int)l, p);
    if (n < 0) break;
    o += (size_t)n < sizeof(out) - o ? (size_t)n : sizeof(out) - o - 1;
    if (!e) break;
    p = e + 1;
  }
  if (o > 0 && out[o - 1] == '\n') out[o - 1] = '\0';
  return strdup(out);
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

  // The exact string is authoritative. Only when it is absent is the
  // line-number-stripped spelling tried, and only if that one resolves.
  char* stripped = NULL;
  if (matches == 0) {
    int changed = 0;
    stripped = bender_strip_line_prefixes(old_str, &changed);
    if (stripped && changed) {
      size_t stripped_matches = bender_count_matches(content, stripped);
      if (stripped_matches > 0) {
        old_str = stripped;
        matches = stripped_matches;
      }
    }
  }

  if (matches == 0) {
    char* hint = bender_nearest_hint(content, old_str);
    char* err;
    if (hint) {
      err = bender_fmt(
        "error: String to replace not found in %s. The closest text found is:\n%s\n"
        "Copy from there exactly, without the \"N<tab>\" prefix Read adds.\n"
        "Your string was:\n%s", path, hint, old_str);
      free(hint);
    } else {
      err = bender_fmt(
        "error: String to replace not found in %s, and no part of it appears in "
        "the file at all — re-read the file before editing it.\nYour string was:\n%s",
        path, old_str);
    }
    free(stripped);
    free(content);
    return err;
  }
  if (matches > 1 && !replace_all) {
    char* err = bender_fmt(
      "error: Found %zu matches of the string to replace in %s, but replace_all is false. "
      "To replace all occurrences set replace_all to true. To replace one occurrence, "
      "provide more context to uniquely identify the instance.\nString: %s",
      matches, path, old_str);
    free(stripped);
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
  free(stripped);
  if (!updated) return strdup("error: out of memory");

  char* err = bender_write_bytes(path, updated, updated_len);
  free(updated);
  if (err) return err;

  return replace_all
    ? bender_fmt("The file %s has been updated. All %zu occurrences were successfully replaced.", path, matches)
    : bender_fmt("The file %s has been updated successfully.", path);
}

// ----------------------------------------------------------------------------
// Grep
// ----------------------------------------------------------------------------
// Literal (not regular-expression) search. A file is searched on its own and
// matches render as "N:line"; a directory is searched recursively and matches
// render as "path:N:line", the spelling grep itself uses, so a result can be
// handed straight to Read or Edit.

// Matches are capped on both counts because the result goes into the agent's
// state: a common pattern over a whole tree would otherwise crowd out
// everything else the agent had learned.
#define BENDER_GREP_MAX_MATCHES 200
#define BENDER_GREP_MAX_LINE 500
#define BENDER_GREP_MAX_FILE_SIZE (1024 * 1024)

// Lines shown on either side of a hit, like grep -C. A bare "path:N:line"
// says where a match is but nothing about what contains it — which function,
// which struct — and the model invented the rest.
#define BENDER_GREP_CONTEXT 3

// The shortest piece of a missed pattern worth reporting (shorter pieces
// match everywhere and say nothing), how many file names the report lists,
// and the room kept for them.
#define BENDER_FRAG_MIN 4
#define BENDER_FRAG_MAX_NAMES 6
#define BENDER_FRAG_NAMES_CAP 768

typedef struct {
  char* data;
  size_t len;
  size_t cap;
  size_t matches;
  int truncated;
  int failed;
} GrepSink;

static void grep_sink_put(GrepSink* g, const char* text, size_t len) {
  if (g->failed) return;
  if (g->len + len + 1 > g->cap) {
    size_t cap = (g->len + len + 1) * 2;
    char* grown = (char*)realloc(g->data, cap);
    if (!grown) { g->failed = 1; return; }
    g->data = grown;
    g->cap = cap;
  }
  memcpy(g->data + g->len, text, len);
  g->len += len;
  g->data[g->len] = '\0';
}

static void grep_sink_fmt(GrepSink* g, const char* fmt, ...) {
  if (g->failed) return;
  va_list ap;
  va_start(ap, fmt);
  char buf[BENDER_GREP_MAX_LINE + 512];
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0) grep_sink_put(g, buf, (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1);
}

// The line-level test. The first pass is an exact substring match; the retry
// a miss earns is case-insensitive and walks the line a byte at a time.
static int line_has(const char* line, const char* pattern, int ci) {
  if (!ci) return strstr(line, pattern) != NULL;
  size_t plen = strlen(pattern);
  for (const char* p = line; *p; p++) {
    if (strncasecmp(p, pattern, plen) == 0) return 1;
  }
  return 0;
}

// One output line. Matches use ':' ("path:N:line"), context uses '-'
// ("path-N-line"), the convention grep -C prints.
static void grep_emit(GrepSink* g, const char* label, size_t line_no,
                      const char* text, size_t line_len, char sep) {
  size_t shown = line_len > BENDER_GREP_MAX_LINE ? BENDER_GREP_MAX_LINE : line_len;
  const char* clip = shown < line_len ? " ..." : "";
  if (label) {
    grep_sink_fmt(g, "%s%c%zu%c%.*s%s\n", label, sep, line_no, sep,
                  (int)shown, text, clip);
  } else {
    grep_sink_fmt(g, "%zu%c%.*s%s\n", line_no, sep, (int)shown, text, clip);
  }
}

// Scans one file's bytes. `label` prefixes each line when searching a tree,
// and is NULL for a single-file search. Hits carry BENDER_GREP_CONTEXT lines
// on either side, with a "--" between blocks that do not touch.
static void grep_scan(GrepSink* g, const char* pattern, const char* label,
                      char* text, size_t len, int ci) {
  // The ring holds the last few lines not yet emitted, so a hit can show the
  // lines just above it.
  size_t ring_off[BENDER_GREP_CONTEXT];
  size_t ring_len[BENDER_GREP_CONTEXT];
  int ring_n = 0;
  long emitted = 0;  // highest line number written so far
  int after = 0;     // trailing context lines still owed to the last hit

  size_t line_no = 1;
  size_t i = 0;
  while (i <= len) {
    if (g->truncated || g->failed) return;
    size_t line_end = i;
    while (line_end < len && text[line_end] != '\n') line_end++;

    size_t line_len = line_end - i;
    if (line_len > 0 && text[i + line_len - 1] == '\r') line_len--;  // CRLF
    // The position after a final newline is a phantom line, not a real one:
    // it can never match, and as context it would read as a stray blank.
    if (line_len == 0 && line_end >= len) break;

    // The line is NUL-terminated in place for the search and put back after,
    // which keeps the scan allocation-free.
    char saved = text[i + line_len];
    text[i + line_len] = '\0';
    int hit = line_has(text + i, pattern, ci);
    text[i + line_len] = saved;

    if (hit) {
      if (g->matches >= BENDER_GREP_MAX_MATCHES) {
        g->truncated = 1;
        return;
      }
      // Leading context comes out of the ring; lines already shown stay shown,
      // and a gap between blocks is marked the way grep marks it.
      long ctx_from = (long)line_no - ring_n;
      if (ctx_from < emitted + 1) ctx_from = emitted + 1;
      long first_out = ctx_from < (long)line_no ? ctx_from : (long)line_no;
      if (emitted > 0 && first_out > emitted + 1) grep_sink_put(g, "--\n", 3);
      for (int k = 0; k < ring_n; k++) {
        long ctx_no = (long)line_no - ring_n + k;
        if (ctx_no < ctx_from) continue;
        grep_emit(g, label, (size_t)ctx_no, text + ring_off[k], ring_len[k], '-');
      }
      grep_emit(g, label, line_no, text + i, line_len, ':');
      g->matches++;
      emitted = (long)line_no;
      after = BENDER_GREP_CONTEXT;
      ring_n = 0;
    } else if (after > 0) {
      grep_emit(g, label, line_no, text + i, line_len, '-');
      emitted = (long)line_no;
      after--;
    } else {
      if (ring_n == BENDER_GREP_CONTEXT) {
        memmove(ring_off, ring_off + 1, sizeof(ring_off[0]) * (BENDER_GREP_CONTEXT - 1));
        memmove(ring_len, ring_len + 1, sizeof(ring_len[0]) * (BENDER_GREP_CONTEXT - 1));
        ring_n--;
      }
      ring_off[ring_n] = i;
      ring_len[ring_n] = line_len;
      ring_n++;
    }

    line_no++;
    if (line_end >= len) break;
    i = line_end + 1;
  }
}

// Binary files have no lines worth showing and would corrupt the state, so a
// NUL byte near the head is taken as the signal to skip the file.
static int grep_looks_binary(const char* text, size_t len) {
  size_t check = len < 8192 ? len : 8192;
  return memchr(text, '\0', check) != NULL;
}

static void grep_file(GrepSink* g, const char* pattern, const char* path,
                      const char* label, int ci) {
  struct stat st;
  if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return;
  if (st.st_size > BENDER_GREP_MAX_FILE_SIZE) return;
  size_t len = 0;
  char* text = bender_slurp(path, &len);
  if (!text) return;
  if (!grep_looks_binary(text, len)) grep_scan(g, pattern, label, text, len, ci);
  free(text);
}

// Tracked files only, the way ripgrep searches by default. A working directory
// holds build output that git ignores but a tree walk does not: here, 450 KB of
// generated C that is larger than the entire source tree and full of plausible
// matches. `git ls-files` answers this authoritatively; outside a repository
// the set stays empty and everything is searched, which is the right fallback.
static char* tracked_files = NULL;

static void tracked_files_load(void) {
  if (tracked_files) return;
  FILE* p = popen("git ls-files 2>/dev/null", "r");
  if (!p) { tracked_files = strdup(""); return; }
  size_t cap = 8192, len = 0;
  char* buf = (char*)malloc(cap);
  if (!buf) { pclose(p); tracked_files = strdup(""); return; }
  buf[0] = '\n';
  len = 1;
  char line[1024];
  while (fgets(line, sizeof(line), p)) {
    size_t l = strlen(line);
    if (len + l + 2 > cap) {
      cap = (len + l + 2) * 2;
      char* grown = (char*)realloc(buf, cap);
      if (!grown) break;
      buf = grown;
    }
    memcpy(buf + len, line, l);
    len += l;
    if (line[l - 1] != '\n') buf[len++] = '\n';
  }
  pclose(p);
  buf[len] = '\0';
  tracked_files = buf;
}

// Empty set means "not a repository": search everything rather than nothing.
static int is_tracked(const char* path) {
  tracked_files_load();
  if (!tracked_files || tracked_files[1] == '\0') return 1;
  char needle[1200];
  snprintf(needle, sizeof(needle), "\n%s\n", path);
  return strstr(tracked_files, needle) != NULL;
}

// `tracked_only` is set when the search root is a relative path, i.e. inside
// this repository. An absolute path is somewhere else entirely and the
// repository's tracked set says nothing useful about it.
static void grep_tree(GrepSink* g, const char* pattern, const char* dir,
                      int tracked_only, int ci) {
  if (g->truncated || g->failed) return;
  DIR* d = opendir(dir);
  if (!d) return;
  struct dirent* entry;
  while ((entry = readdir(d)) != NULL) {
    if (entry->d_name[0] == '.') continue;  // . .. .git and other dot entries
    char child[1024];
    // "./x" reads worse than "x" in a result a model will quote back.
    if (strcmp(dir, ".") == 0) {
      snprintf(child, sizeof(child), "%s", entry->d_name);
    } else {
      snprintf(child, sizeof(child), "%s/%s", dir, entry->d_name);
    }
    if (bender_is_dir(child)) {
      grep_tree(g, pattern, child, tracked_only, ci);
    } else if (!tracked_only || is_tracked(child)) {
      grep_file(g, pattern, child, child, ci);
    }
    if (g->truncated || g->failed) break;
  }
  closedir(d);
}

// One pass over the search scope: a file on its own, or the tree under a
// directory.
static void grep_run(GrepSink* g, const char* pattern, const char* path, int ci) {
  if (bender_is_dir(path)) {
    grep_tree(g, pattern, path, path[0] != '/', ci);
  } else {
    grep_file(g, pattern, path, NULL, ci);
  }
}

// ----------------------------------------------------------------------------
// What a miss should say
// ----------------------------------------------------------------------------
// "No matches" alone is a dead end: the model guessed a name, guessed wrong,
// and learned nothing about which part of the guess was real, so it guesses
// again in the same shape. A miss therefore earns a case-insensitive retry,
// and if that finds nothing either, the longest prefix and suffix of the
// pattern that DO appear are reported along with where, so the next guess
// starts from a piece of something real.

// Substring search over counted bytes — the needles are pieces of the
// pattern, not NUL-terminated strings of their own. Case-insensitive, like
// the retry that runs just before this.
static const char* bender_memmem(const char* hay, size_t haylen,
                                 const char* needle, size_t nlen) {
  if (nlen == 0) return hay;
  if (nlen > haylen) return NULL;
  for (size_t i = 0; i + nlen <= haylen; i++) {
    if (strncasecmp(hay + i, needle, nlen) == 0) return hay + i;
  }
  return NULL;
}

typedef struct {
  const char* pat;
  size_t plen;
  size_t best_pre, best_suf;   // longest prefix/suffix of pat seen anywhere
  size_t pre_files, suf_files; // how many files contain them
  int pre_named, suf_named;    // how many of those names were kept
  char pre_names[BENDER_FRAG_NAMES_CAP];
  char suf_names[BENDER_FRAG_NAMES_CAP];
} FragScan;

// The longest edge-piece of the pattern present in a buffer. Presence is
// monotone — if a piece of length k occurs, every shorter piece along the
// same edge occurs inside it — so binary search needs only a few probes.
static size_t frag_longest(const char* text, size_t len, const char* pat,
                           size_t plen, int suffix) {
  size_t lo = 0, hi = plen - 1;  // the whole pattern already missed
  while (lo < hi) {
    size_t mid = lo + (hi - lo + 1) / 2;
    const char* needle = suffix ? pat + plen - mid : pat;
    if (bender_memmem(text, len, needle, mid)) lo = mid; else hi = mid - 1;
  }
  return lo;
}

// Files are counted only against the longest piece: any file containing the
// best fragment has it as its own longest, so the counts stay exact as the
// best grows.
static void frag_count(FragScan* fs, int suffix, size_t k, const char* path) {
  size_t* best = suffix ? &fs->best_suf : &fs->best_pre;
  size_t* files = suffix ? &fs->suf_files : &fs->pre_files;
  int* named = suffix ? &fs->suf_named : &fs->pre_named;
  char* names = suffix ? fs->suf_names : fs->pre_names;
  if (k == 0 || k < *best) return;
  if (k > *best) {
    *best = k;
    *files = 0;
    *named = 0;
    names[0] = '\0';
  }
  (*files)++;
  if (*named < BENDER_FRAG_MAX_NAMES) {
    size_t used = strlen(names);
    snprintf(names + used, BENDER_FRAG_NAMES_CAP - used, "%s%s",
             used ? ", " : "", path);
    (*named)++;
  }
}

static void frag_scan_file(FragScan* fs, const char* path) {
  struct stat st;
  if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return;
  if (st.st_size > BENDER_GREP_MAX_FILE_SIZE) return;
  size_t len = 0;
  char* text = bender_slurp(path, &len);
  if (!text) return;
  if (!grep_looks_binary(text, len)) {
    frag_count(fs, 0, frag_longest(text, len, fs->pat, fs->plen, 0), path);
    frag_count(fs, 1, frag_longest(text, len, fs->pat, fs->plen, 1), path);
  }
  free(text);
}

// The same walk as grep_tree, kept separate because one collects lines and
// the other collects lengths.
static void frag_tree(FragScan* fs, const char* dir, int tracked_only) {
  DIR* d = opendir(dir);
  if (!d) return;
  struct dirent* entry;
  while ((entry = readdir(d)) != NULL) {
    if (entry->d_name[0] == '.') continue;
    char child[1024];
    if (strcmp(dir, ".") == 0) {
      snprintf(child, sizeof(child), "%s", entry->d_name);
    } else {
      snprintf(child, sizeof(child), "%s/%s", dir, entry->d_name);
    }
    if (bender_is_dir(child)) {
      frag_tree(fs, child, tracked_only);
    } else if (!tracked_only || is_tracked(child)) {
      frag_scan_file(fs, child);
    }
  }
  closedir(d);
}

// On a complete miss — nothing matched, even case-insensitively — report the
// longest pieces of the pattern that do appear and the files holding them.
static char* grep_fragment_hint(const char* pattern, const char* path, int is_dir) {
  size_t plen = strlen(pattern);
  // A fragment is always shorter than the pattern, so a pattern this small
  // has no piece long enough to be worth reporting.
  if (plen <= BENDER_FRAG_MIN) return NULL;

  FragScan fs;
  memset(&fs, 0, sizeof(fs));
  fs.pat = pattern;
  fs.plen = plen;
  if (is_dir) {
    frag_tree(&fs, path, path[0] != '/');
  } else {
    frag_scan_file(&fs, path);
  }
  if (fs.best_pre < BENDER_FRAG_MIN && fs.best_suf < BENDER_FRAG_MIN) return NULL;

  char pre_txt[96], suf_txt[96];
  snprintf(pre_txt, sizeof(pre_txt), "%.*s",
           (int)(fs.best_pre < 90 ? fs.best_pre : 90), pattern);
  snprintf(suf_txt, sizeof(suf_txt), "%.*s",
           (int)(fs.best_suf < 90 ? fs.best_suf : 90), pattern + plen - fs.best_suf);
  // The same piece can be both edges' best (a pattern like "ABXAB" missing
  // where "AB" occurs); report it once rather than twice.
  int same_piece = fs.best_pre >= BENDER_FRAG_MIN &&
                   fs.best_pre == fs.best_suf &&
                   strcmp(pre_txt, suf_txt) == 0;

  GrepSink m = {NULL, 0, 0, 0, 0, 0};
  grep_sink_fmt(&m, " Pieces of it do appear:");
  if (fs.best_pre >= BENDER_FRAG_MIN) {
    if (is_dir) {
      grep_sink_fmt(&m, "\n- '%s'%s in %zu file%s: %s%s", pre_txt,
                    same_piece ? "" : " (prefix)",
                    fs.pre_files, fs.pre_files == 1 ? "" : "s",
                    fs.pre_names,
                    fs.pre_files > (size_t)fs.pre_named ? ", ..." : "");
    } else {
      grep_sink_fmt(&m, "\n- '%s'%s in this file", pre_txt,
                    same_piece ? "" : " (prefix)");
    }
  }
  if (!same_piece && fs.best_suf >= BENDER_FRAG_MIN) {
    if (is_dir) {
      grep_sink_fmt(&m, "\n- '%s' (suffix) in %zu file%s: %s%s", suf_txt,
                    fs.suf_files, fs.suf_files == 1 ? "" : "s",
                    fs.suf_names,
                    fs.suf_files > (size_t)fs.suf_named ? ", ..." : "");
    } else {
      grep_sink_fmt(&m, "\n- '%s' (suffix) in this file", suf_txt);
    }
  }
  grep_sink_fmt(&m, "\nA shorter pattern, or one of these pieces, will hit.");
  if (m.failed || !m.data) {
    free(m.data);
    return NULL;
  }
  return m.data;
}

// Searches `path` for the literal `pattern`. Returns the matches with their
// context lines, a message when there are none, or "error: " text.
static char* tool_grep(const char* pattern, const char* path) {
  if (!pattern || pattern[0] == '\0') {
    return strdup("error: The search pattern is empty, which would match every line.");
  }
  if (!bender_exists(path)) {
    return bender_fmt("error: File does not exist: %s", path);
  }

  GrepSink g = {NULL, 0, 0, 0, 0, 0};
  grep_run(&g, pattern, path, 0);
  if (g.failed) {
    free(g.data);
    return strdup("error: out of memory");
  }

  if (g.matches == 0) {
    free(g.data);
    // A miss earns a second pass, case-insensitive: when the only thing wrong
    // with the guess was its case, the hits are still worth having.
    GrepSink gi = {NULL, 0, 0, 0, 0, 0};
    grep_run(&gi, pattern, path, 1);
    if (gi.failed) {
      free(gi.data);
      return strdup("error: out of memory");
    }
    if (gi.matches > 0) {
      if (gi.truncated) {
        grep_sink_fmt(&gi, "... (stopped at %d matches; narrow the pattern)\n",
                      BENDER_GREP_MAX_MATCHES);
      }
      if (gi.len > 0 && gi.data[gi.len - 1] == '\n') gi.data[--gi.len] = '\0';
      char* out = bender_fmt(
        "No matches found for '%s' in %s, but a case-insensitive search found %zu:\n%s",
        pattern, path, gi.matches, gi.data);
      free(gi.data);
      return out;
    }
    free(gi.data);

    // Still nothing, even ignoring case: say which pieces of the pattern do
    // occur and where, so the next guess starts from something real.
    char* hint = grep_fragment_hint(pattern, path, bender_is_dir(path));
    char* out = hint
      ? bender_fmt("No matches found for '%s' in %s.%s", pattern, path, hint)
      : bender_fmt("No matches found for '%s' in %s.", pattern, path);
    free(hint);
    return out;
  }

  if (g.truncated) {
    grep_sink_fmt(&g, "... (stopped at %d matches; narrow the pattern)\n",
                  BENDER_GREP_MAX_MATCHES);
  }
  // The trailing newline belongs to the last line, not to the result.
  if (g.len > 0 && g.data[g.len - 1] == '\n') g.data[--g.len] = '\0';
  return g.data;
}

#endif  // BENDER_TOOLS_C_H
