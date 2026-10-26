/* Tree-sitter for Swan: parses a file with one of the bundled grammars and
   hands the tree to Goose as a flat array of nodes, so nothing of
   tree-sitter's (TSNode is a struct passed by value) crosses into Goose but
   an opaque i64 handle and plain slices. Memory stays C's: the tree lives
   until swan_ts_free. */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <tree_sitter/api.h>

typedef struct { const uint8_t *data; int64_t len; } ts_slice;
typedef struct { int32_t *data; int64_t len; } ts_ints;
typedef struct { int64_t *data; int64_t len; } ts_ints64;

const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_rust(void);
const TSLanguage *tree_sitter_java(void);
const TSLanguage *tree_sitter_c(void);
const TSLanguage *tree_sitter_cpp(void);
const TSLanguage *tree_sitter_cuda(void);

static bool is(ts_slice s, const char *name) {
    size_t n = strlen(name);
    return (size_t)s.len == n && memcmp(s.data, name, n) == 0;
}

static const TSLanguage *language(ts_slice name) {
    if (is(name, "typescript")) return tree_sitter_typescript();
    if (is(name, "tsx")) return tree_sitter_tsx();
    if (is(name, "javascript")) return tree_sitter_javascript();
    if (is(name, "python")) return tree_sitter_python();
    if (is(name, "rust")) return tree_sitter_rust();
    if (is(name, "java")) return tree_sitter_java();
    if (is(name, "c")) return tree_sitter_c();
    if (is(name, "cpp")) return tree_sitter_cpp();
    if (is(name, "cuda")) return tree_sitter_cuda();
    return NULL;
}

/* A tree for src in the named language, or 0 for a language Swan has no
   grammar for. */
int64_t swan_ts_parse(ts_slice lang, ts_slice src) {
    const TSLanguage *l = language(lang);
    if (!l) return 0;
    TSParser *p = ts_parser_new();
    if (!ts_parser_set_language(p, l)) { ts_parser_delete(p); return 0; }
    TSTree *t = ts_parser_parse_string(p, NULL, (const char *)src.data, (uint32_t)src.len);
    ts_parser_delete(p);
    return (int64_t)(intptr_t)t;
}

void swan_ts_free(int64_t h) { if (h) ts_tree_delete((TSTree *)(intptr_t)h); }

/* How many nodes the tree has, anonymous ones (punctuation) included. */
int64_t swan_ts_count(int64_t h) {
    TSTreeCursor c = ts_tree_cursor_new(ts_tree_root_node((TSTree *)(intptr_t)h));
    int64_t n = 0;
    for (;;) {
        n++;
        if (ts_tree_cursor_goto_first_child(&c)) continue;
        while (!ts_tree_cursor_goto_next_sibling(&c))
            if (!ts_tree_cursor_goto_parent(&c)) { ts_tree_cursor_delete(&c); return n; }
    }
}

enum { F_NAMED = 1, F_EXTRA = 2, F_ERROR = 4 };
enum { R_SYM, R_FLAGS, R_START, R_END, R_ROW, R_COL, R_FIRST, R_NEXT, R_SIZE };

/* The nodes in pre-order, R_SIZE ints each: symbol, flags, start and end
   byte, start row and column (0-based), and the indexes of the first child
   and the next sibling (-1 for none). Returns how many were written. */
int64_t swan_ts_fill(int64_t h, ts_ints out) {
    TSTreeCursor c = ts_tree_cursor_new(ts_tree_root_node((TSTree *)(intptr_t)h));
    int64_t cap = 64, depth = 0, n = 0, max = out.len / R_SIZE;
    int32_t *last = malloc(cap * sizeof *last), *parent = malloc(cap * sizeof *parent);
    last[0] = -1; parent[0] = -1;
    for (;;) {
        if (n >= max) break;
        TSNode node = ts_tree_cursor_current_node(&c);
        int32_t *r = out.data + n * R_SIZE;
        r[R_SYM] = ts_node_symbol(node);
        r[R_FLAGS] = (ts_node_is_named(node) ? F_NAMED : 0) | (ts_node_is_extra(node) ? F_EXTRA : 0) |
                     (ts_node_is_error(node) || ts_node_is_missing(node) ? F_ERROR : 0);
        r[R_START] = (int32_t)ts_node_start_byte(node);
        r[R_END] = (int32_t)ts_node_end_byte(node);
        TSPoint pt = ts_node_start_point(node);
        r[R_ROW] = (int32_t)pt.row;
        r[R_COL] = (int32_t)pt.column;
        r[R_FIRST] = -1;
        r[R_NEXT] = -1;
        if (last[depth] >= 0) out.data[last[depth] * R_SIZE + R_NEXT] = (int32_t)n;
        else if (parent[depth] >= 0) out.data[parent[depth] * R_SIZE + R_FIRST] = (int32_t)n;
        last[depth] = (int32_t)n;
        int32_t me = (int32_t)n++;
        if (ts_tree_cursor_goto_first_child(&c)) {
            if (++depth >= cap) {
                cap *= 2;
                last = realloc(last, cap * sizeof *last);
                parent = realloc(parent, cap * sizeof *parent);
            }
            last[depth] = -1;
            parent[depth] = me;
            continue;
        }
        bool done = false;
        while (!ts_tree_cursor_goto_next_sibling(&c)) {
            if (!ts_tree_cursor_goto_parent(&c)) { done = true; break; }
            depth--;
        }
        if (done) break;
    }
    free(last);
    free(parent);
    ts_tree_cursor_delete(&c);
    return n;
}

/* A symbol's name ("call_expression", or the text of a token such as "(")
   into buf; returns its length. */
int64_t swan_ts_kind(int64_t h, int64_t sym, ts_slice buf) {
    const char *s = ts_language_symbol_name(ts_tree_language((TSTree *)(intptr_t)h), (TSSymbol)sym);
    size_t n = s ? strlen(s) : 0;
    if ((int64_t)n > buf.len) n = (size_t)buf.len;
    memcpy((uint8_t *)buf.data, s, n);
    return (int64_t)n;
}

/* Parsing many files at once, on several threads: tree-sitter parses one
   file per parser, and parsers are independent. paths is NUL-separated;
   handles[i] gets file i's tree, or 0 if it could not be read. */
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

typedef struct {
    const TSLanguage *lang;
    char **paths;
    int64_t *handles;
    int64_t n;
    int64_t next;
    pthread_mutex_t mu;
} batch_t;

static void *batch_worker(void *arg) {
    batch_t *b = arg;
    TSParser *p = ts_parser_new();
    ts_parser_set_language(p, b->lang);
    for (;;) {
        pthread_mutex_lock(&b->mu);
        int64_t i = b->next++;
        pthread_mutex_unlock(&b->mu);
        if (i >= b->n) break;
        FILE *f = fopen(b->paths[i], "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long len = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *buf = malloc(len > 0 ? (size_t)len : 1);
        size_t got = fread(buf, 1, (size_t)len, f);
        fclose(f);
        b->handles[i] = (int64_t)(intptr_t)ts_parser_parse_string(p, NULL, buf, (uint32_t)got);
        ts_parser_reset(p);
        free(buf);
    }
    ts_parser_delete(p);
    return NULL;
}

/* Returns how many files were given, or -1 for a language without a grammar. */
int64_t swan_ts_parse_files(ts_slice lang, ts_slice paths_nul, ts_ints64 handles) {
    const TSLanguage *l = language(lang);
    if (!l) return -1;
    batch_t b = {l, NULL, handles.data, 0, 0, PTHREAD_MUTEX_INITIALIZER};
    for (int64_t i = 0; i < paths_nul.len; i++) if (paths_nul.data[i] == 0) b.n++;
    if (b.n > handles.len) b.n = handles.len;
    b.paths = calloc((size_t)b.n + 1, sizeof *b.paths);
    for (int64_t i = 0, k = 0, at = 0; i < paths_nul.len && k < b.n; i++)
        if (paths_nul.data[i] == 0) { b.paths[k++] = (char *)paths_nul.data + at; at = i + 1; }
    for (int64_t i = 0; i < b.n; i++) handles.data[i] = 0;
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    int64_t nt = cpus > 1 ? (cpus > 16 ? 16 : cpus) : 1;
    if (nt > b.n) nt = b.n;
    pthread_t th[16];
    for (int64_t t = 0; t < nt; t++) pthread_create(&th[t], NULL, batch_worker, &b);
    for (int64_t t = 0; t < nt; t++) pthread_join(th[t], NULL);
    free(b.paths);
    return b.n;
}

/* The nodes of a tree made by swan_ts_parse_files, as swan_ts_count and
   swan_ts_fill give them. */
