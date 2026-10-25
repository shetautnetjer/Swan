// SQLite through native/swan_sqlite.c. A database or a prepared statement is
// an i64 handle; 0 means it failed and the reason is in `err`.

extern fn swan_db_open(path: const u8[:], err: u8[>..]&) -> i64;
extern fn swan_db_close(db: i64);
extern fn swan_db_exec(db: i64, sql: const u8[:], err: u8[>..]&) -> bool;
extern fn swan_stmt_prepare(db: i64, sql: const u8[:], err: u8[>..]&) -> i64;
extern fn swan_bind_text(st: i64, i: i32, v: const u8[:]) -> bool;
extern fn swan_bind_int(st: i64, i: i32, v: i64) -> bool;
extern fn swan_step(st: i64, err: u8[>..]&) -> i32;     // 1 a row, 0 done, -1 an error
extern fn swan_col_int(st: i64, i: i32) -> i64;
extern fn swan_col_text(st: i64, i: i32, out: u8[>..]&);
extern fn swan_reset(st: i64);
extern fn swan_finalize(st: i64);
extern fn swan_mtime_ns(path: const u8[:]) -> i64;     // -1 if the file cannot be read

fn exec_or_die(db: i64, sql: const u8[:]) {
    var err: u8[>..] = [];
    if !swan_db_exec(db, sql, err) { abort(str("sqlite: ", err, " in: ", sql)); }
}

fn prepare_or_die(db: i64, sql: const u8[:]) -> i64 {
    var err: u8[>..] = [];
    let st = swan_stmt_prepare(db, sql, err);
    if st == 0 { abort(str("sqlite: ", err, " in: ", sql)); }
    return st;
}

// Runs an insert or update that was bound already, then resets it.
fn step_done(st: i64) {
    var err: u8[>..] = [];
    if swan_step(st, err) < 0 { abort(str("sqlite: ", err)); }
    swan_reset(st);
}
