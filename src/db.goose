// The map's database: SQLite through the goose-sqlite package. These are
// the helpers Swan uses everywhere; a handle of 0 means it failed.

import std;
import sqlite;

extern fn swan_mtime_ns(path: const u8[:]) -> i64;     // -1 if the file cannot be read (native/swan_sys.c)

fn exec_or_die(db: i64, sql: const u8[:]) { sqlite::exec_or_die(db, sql); }
fn prepare_or_die(db: i64, sql: const u8[:]) -> i64 { return sqlite::prepare_or_die(db, sql); }
fn step_done(st: i64) { sqlite::step_done(st); }
