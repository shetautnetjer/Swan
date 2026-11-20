// The map's database: SQLite through its C API (libsqlite3-sys, built in,
// the same SQLite release the goose-sqlite package builds). A database, a
// prepared statement, parameters from 1, columns from 0, text as bytes.
// Carried over from src/db.goose and goose-sqlite's sqlite.goose and gsq.c.

use crate::util::die;
use libsqlite3_sys as ffi;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

pub struct Db(*mut ffi::sqlite3);
pub struct Stmt(*mut ffi::sqlite3_stmt);

unsafe fn errmsg(db: *mut ffi::sqlite3) -> Vec<u8> {
    if db.is_null() {
        return b"out of memory".to_vec();
    }
    CStr::from_ptr(ffi::sqlite3_errmsg(db)).to_bytes().to_vec()
}

fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

// goose-sqlite builds SQLite with SQLITE_THREADSAFE=0 and
// SQLITE_DEFAULT_MEMSTATUS=0, and without SQLITE_USE_URI: one thread, no
// locks, no count kept of every allocation, and a path that starts with
// "file:" is a file of that name. The crate builds SQLite the other way in
// all three, so the same is asked for here, once, before the first database
// is opened. Swan uses SQLite from one thread only.
unsafe fn configure() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        ffi::sqlite3_config(ffi::SQLITE_CONFIG_SINGLETHREAD);
        ffi::sqlite3_config(ffi::SQLITE_CONFIG_MEMSTATUS, 0 as c_int);
        ffi::sqlite3_config(ffi::SQLITE_CONFIG_URI, 0 as c_int);
    });
}

impl Db {
    fn open_flags(path: &[u8], flags: c_int) -> Result<Db, Vec<u8>> {
        if path.is_empty() || path.len() >= 4096 {
            return Err(b"bad path".to_vec());
        }
        let c = CString::new(path).map_err(|_| b"bad path".to_vec())?;
        let mut db: *mut ffi::sqlite3 = ptr::null_mut();
        unsafe {
            configure();
            if ffi::sqlite3_open_v2(c.as_ptr(), &mut db, flags, ptr::null()) != ffi::SQLITE_OK {
                let e = errmsg(db);
                ffi::sqlite3_close(db);
                return Err(e);
            }
            // SQLITE_DQS=0, as goose-sqlite builds it: text in double quotes
            // is a name, never a string, so a slip in a statement is an
            // error in both programs and not a silent string in this one.
            ffi::sqlite3_db_config(db, ffi::SQLITE_DBCONFIG_DQS_DML, 0 as c_int, ptr::null_mut::<c_int>());
            ffi::sqlite3_db_config(db, ffi::SQLITE_DBCONFIG_DQS_DDL, 0 as c_int, ptr::null_mut::<c_int>());
        }
        Ok(Db(db))
    }

    /// Creates the file if needed.
    pub fn open(path: &[u8]) -> Result<Db, Vec<u8>> {
        Db::open_flags(path, ffi::SQLITE_OPEN_READWRITE | ffi::SQLITE_OPEN_CREATE)
    }

    /// Read and write; never creates a missing map.
    pub fn open_existing(path: &[u8]) -> Result<Db, Vec<u8>> {
        Db::open_flags(path, ffi::SQLITE_OPEN_READWRITE)
    }

    /// One or more statements that return no rows.
    pub fn exec(&self, sql: &[u8]) -> Result<(), Vec<u8>> {
        let c = CString::new(sql).map_err(|_| b"SQL holds a NUL byte".to_vec())?;
        unsafe {
            if ffi::sqlite3_exec(self.0, c.as_ptr(), None, ptr::null_mut(), ptr::null_mut()) != ffi::SQLITE_OK {
                return Err(errmsg(self.0));
            }
        }
        Ok(())
    }

    // The same, ending the run with SQLite's message on failure: for
    // statements that are part of the program, where failing is a bug.
    pub fn exec_or_die(&self, sql: &[u8]) {
        if let Err(e) = self.exec(sql) {
            die(&cat(&[b"sqlite: ", &e, b" in: ", sql]));
        }
    }

    pub fn prepare(&self, sql: &[u8]) -> Result<Stmt, Vec<u8>> {
        let mut st: *mut ffi::sqlite3_stmt = ptr::null_mut();
        unsafe {
            if ffi::sqlite3_prepare_v2(self.0, sql.as_ptr() as *const c_char, sql.len() as c_int, &mut st, ptr::null_mut())
                != ffi::SQLITE_OK
            {
                return Err(errmsg(self.0));
            }
        }
        Ok(Stmt(st))
    }

    pub fn prepare_or_die(&self, sql: &[u8]) -> Stmt {
        match self.prepare(sql) {
            Ok(s) => s,
            Err(e) => die(&cat(&[b"sqlite: ", &e, b" in: ", sql])),
        }
    }
}

impl Drop for Db {
    // Every statement is dropped before its database here, so the plain
    // close does what goose-sqlite's close_v2 does (the crate's bindings
    // have no close_v2).
    fn drop(&mut self) {
        unsafe {
            ffi::sqlite3_close(self.0);
        }
    }
}

impl Stmt {
    pub fn bind_text(&self, i: i32, v: &[u8]) {
        unsafe {
            ffi::sqlite3_bind_text(self.0, i, v.as_ptr() as *const c_char, v.len() as c_int, ffi::SQLITE_TRANSIENT());
        }
    }

    pub fn bind_int(&self, i: i32, v: i64) {
        unsafe {
            ffi::sqlite3_bind_int64(self.0, i, v);
        }
    }

    /// A row (true) or done (false); an error comes back as its text.
    pub fn step(&self) -> Result<bool, Vec<u8>> {
        unsafe {
            match ffi::sqlite3_step(self.0) {
                ffi::SQLITE_ROW => Ok(true),
                ffi::SQLITE_DONE => Ok(false),
                _ => Err(errmsg(ffi::sqlite3_db_handle(self.0))),
            }
        }
    }

    // A failed read must never look like an empty result or an edit
    // precondition that passed: stop with SQLite's reason.
    pub fn step_checked(&self) -> bool {
        match self.step() {
            Ok(row) => row,
            Err(e) => die(&cat(&[b"swan: sqlite read failed: ", &e])),
        }
    }

    // Runs an insert or update that was bound already, then resets it. Rows
    // it returns (RETURNING) are stepped through.
    pub fn step_done(&self) {
        loop {
            match self.step() {
                Ok(true) => {}
                Ok(false) => break,
                Err(e) => die(&cat(&[b"sqlite: ", &e])),
            }
        }
        self.reset();
    }

    pub fn col_int(&self, i: i32) -> i64 {
        unsafe { ffi::sqlite3_column_int64(self.0, i) }
    }

    /// The column as text; empty for NULL.
    pub fn col_text(&self, i: i32) -> Vec<u8> {
        unsafe {
            let p = ffi::sqlite3_column_text(self.0, i);
            if p.is_null() {
                return Vec::new();
            }
            let n = ffi::sqlite3_column_bytes(self.0, i) as usize;
            std::slice::from_raw_parts(p, n).to_vec()
        }
    }

    /// Ready to run again, with no parameters set.
    pub fn reset(&self) {
        unsafe {
            ffi::sqlite3_reset(self.0);
            ffi::sqlite3_clear_bindings(self.0);
        }
    }
}

impl Drop for Stmt {
    fn drop(&mut self) {
        unsafe {
            ffi::sqlite3_finalize(self.0);
        }
    }
}
