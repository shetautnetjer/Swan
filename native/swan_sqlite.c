/* Swan's thin C layer over SQLite. Goose cannot hold a C pointer, so a
   database or statement crosses the `extern fn` boundary as an i64 handle
   (the pointer, cast). Text arrives as a Goose slice { data, len } and goes
   back out by appending to a Goose builder. Every function here is a direct
   wrapper; the logic lives in Goose. */
#include "goose.h"
#include "sqlite3.h"
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } swan_slice;

static void append_cstr(gs_rref out, const char *s) {
    if (s) gs_bld_append(out, s, strlen(s));
}

/* Opens (creating if needed) the database at path. 0 on failure, with the
   reason appended to err. */
int64_t swan_db_open(swan_slice path, gs_rref err) {
    char buf[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof buf) { append_cstr(err, "bad path"); return 0; }
    memcpy(buf, path.data, (size_t)path.len);
    buf[path.len] = 0;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(buf, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
        append_cstr(err, db ? sqlite3_errmsg(db) : "out of memory");
        sqlite3_close(db);
        return 0;
    }
    return (int64_t)(intptr_t)db;
}

void swan_db_close(int64_t h) { sqlite3_close_v2((sqlite3 *)(intptr_t)h); }

/* Runs one or more statements that return no rows. */
bool swan_db_exec(int64_t h, swan_slice sql, gs_rref err) {
    sqlite3 *db = (sqlite3 *)(intptr_t)h;
    const char *p = (const char *)sql.data, *end = p + sql.len;
    while (p < end) {
        sqlite3_stmt *st = NULL;
        const char *tail = NULL;
        if (sqlite3_prepare_v2(db, p, (int)(end - p), &st, &tail) != SQLITE_OK) {
            append_cstr(err, sqlite3_errmsg(db));
            return false;
        }
        if (st) {
            int rc;
            while ((rc = sqlite3_step(st)) == SQLITE_ROW) {}
            sqlite3_finalize(st);
            if (rc != SQLITE_DONE) { append_cstr(err, sqlite3_errmsg(db)); return false; }
        }
        p = tail ? tail : end;
    }
    return true;
}

int64_t swan_stmt_prepare(int64_t h, swan_slice sql, gs_rref err) {
    sqlite3 *db = (sqlite3 *)(intptr_t)h;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, (const char *)sql.data, (int)sql.len, &st, NULL) != SQLITE_OK) {
        append_cstr(err, sqlite3_errmsg(db));
        return 0;
    }
    return (int64_t)(intptr_t)st;
}

bool swan_bind_text(int64_t s, int32_t i, swan_slice v) {
    return sqlite3_bind_text((sqlite3_stmt *)(intptr_t)s, i, (const char *)v.data, (int)v.len,
                             SQLITE_TRANSIENT) == SQLITE_OK;
}

bool swan_bind_int(int64_t s, int32_t i, int64_t v) {
    return sqlite3_bind_int64((sqlite3_stmt *)(intptr_t)s, i, v) == SQLITE_OK;
}

/* 1 a row, 0 done, -1 an error (its text appended to err). */
int32_t swan_step(int64_t s, gs_rref err) {
    sqlite3_stmt *st = (sqlite3_stmt *)(intptr_t)s;
    int rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) return 1;
    if (rc == SQLITE_DONE) return 0;
    append_cstr(err, sqlite3_errmsg(sqlite3_db_handle(st)));
    return -1;
}

int64_t swan_col_int(int64_t s, int32_t i) { return sqlite3_column_int64((sqlite3_stmt *)(intptr_t)s, i); }

void swan_col_text(int64_t s, int32_t i, gs_rref out) {
    sqlite3_stmt *st = (sqlite3_stmt *)(intptr_t)s;
    const unsigned char *t = sqlite3_column_text(st, i);
    if (t) gs_bld_append(out, t, (size_t)sqlite3_column_bytes(st, i));
}

void swan_reset(int64_t s) {
    sqlite3_stmt *st = (sqlite3_stmt *)(intptr_t)s;
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);
}

void swan_finalize(int64_t s) { sqlite3_finalize((sqlite3_stmt *)(intptr_t)s); }

int64_t swan_last_rowid(int64_t h) { return sqlite3_last_insert_rowid((sqlite3 *)(intptr_t)h); }
