// The map's database: SQLite through the goose-sqlite package. These are
// the helpers Swan uses everywhere; a handle of 0 means it failed.

import std;
import sqlite;

extern fn swan_mtime_ns(path: const u8[:]) -> i64;     // -1 if the file cannot be read (native/swan_sys.c)

fn exec_or_die(db: i64, sql: const u8[:]) { sqlite::exec_or_die(db, sql); }
fn prepare_or_die(db: i64, sql: const u8[:]) -> i64 { return sqlite::prepare_or_die(db, sql); }
fn step_done(st: i64) { sqlite::step_done(st); }

// sqlite::step returns -1 on failure, not just 1 (row) or 0 (done). A
// failed read must never look like an empty result or an edit precondition
// that passed. Like prepare_or_die/step_done, stop with SQLite's reason.
fn step_checked(st: i64, err: u8[>..]&) -> i32 {
    let result = sqlite::step(st, err);
    if result < 0 { abort(str("swan: sqlite read failed: ", err)); }
    return result;
}
