// Freshness: whether a file changed after the SCIP run the map was built
// from. Answers about such a file may be out of date, and each one says so
// with "stale": true, so an agent knows to reread the file or refresh the
// map. The check is one stat per file: modified after the SCIP run, or gone.
// A file Swan edited itself is not stale: Swan shifted its rows to match
// (src/edit.goose) and recorded the mtime it left, so only a later outside
// change makes it stale again.

import std;
import os;
import sqlite;

var fresh_root: u8[..4096];
var fresh_scip_time: i64 = 0;    // ns since the epoch; 0 when unknown
var fresh_edited: i64 = 0;       // statement: a file's edited_mtime

// Loads the map's root and SCIP time for `db`, the connection the server
// answers from. Called again after update_map, which moves the SCIP time.
fn load_freshness(db: i64) {
    fresh_root.clear();
    fresh_scip_time = 0;
    if fresh_edited != 0 { sqlite::finalize(fresh_edited); }
    var v: u8[>..] = [];
    meta_value(db, "root", v);
    if v.len > 0 && v.len < 4000 {
        format(fresh_root, v);
        if v[v.len - 1] != '/' { fresh_root.push('/'); }
    }
    var t: u8[>..] = [];
    meta_value(db, "scip_time", t);
    let n, ok = parse_int(t);
    if ok { fresh_scip_time = n; }
    fresh_edited = prepare_or_die(db, "SELECT edited_mtime FROM files WHERE file = ?1");
}

// Lets go of the freshness state before its db closes: the prepared
// statement belongs to that connection. swan serve calls this when it
// switches repos.
fn drop_freshness() {
    fresh_root.clear();
    fresh_scip_time = 0;
    if fresh_edited != 0 { sqlite::finalize(fresh_edited); fresh_edited = 0; }
}

// The mtime Swan left on a file it edited, or -1.
fn edited_mtime(file: const u8[:]) -> i64 {
    guard fresh_edited != 0 else { return -1; }
    var err: u8[>..] = [];
    var t = -1;
    sqlite::bind_text(fresh_edited, 1, file);
    if sqlite::step(fresh_edited, err) == 1 {
        var v: u8[>..] = [];
        sqlite::col_text(fresh_edited, 0, v);
        if v.len > 0 { t = sqlite::col_int(fresh_edited, 0); }
    }
    sqlite::reset(fresh_edited);
    return t;
}

fn is_stale(file: const u8[:]) -> bool {
    guard fresh_scip_time > 0 && fresh_root.len > 0 && file.len > 0 else { return false; }
    var p: u8[>..] = [];
    p.append(fresh_root);
    p.append(file);
    let m = swan_mtime_ns(p);
    if m < 0 { return true; }
    return m > fresh_scip_time && m != edited_mtime(file);
}

// Files added since the map was built: in the repo, never in the map, with
// an ending the map already holds files for, and written after the SCIP run.
// is_stale only checks mapped files, so a new file was missing from every
// answer with nothing saying so (2026-11-01: AEON's new
// app-server-openai-chat-key-store.ts was absent from a reference list).
// Appends "relative/path\n" to out for each one and returns how many.
// Endings come from the map, so a language it never indexed (no indexer
// here, or one waiting for swan trust) never shows. A file the indexers leave
// out on purpose (outside the tsconfig, say) shows only until the next
// refresh moves the SCIP time past it. One walk of the repo, skipping the
// folders `swan map` skips (each_file), and one stat per file with such an
// ending.
fn new_files(db: i64, out: u8[>..]&) -> i64 {
    guard fresh_scip_time > 0 && fresh_root.len > 1 else { return 0; }
    var endings: u8[>..] = [];      // "\n.ts\n.py\n"
    endings.push('\n');
    var err: u8[>..] = [];
    // Only files with rows: mark_edited (src/edit.goose) adds an empty row
    // for any file Swan edits or formats, which must not add its ending.
    let all = prepare_or_die(db, "SELECT file FROM files WHERE rows > 0");
    while sqlite::step(all, err) == 1 {
        var f: u8[>..] = [];
        sqlite::col_text(all, 0, f);
        let e = file_ending(f);
        if e.len > 0 && find(endings, str("\n", e, "\n")) < 0 {
            endings.append(e);
            endings.push('\n');
        }
    }
    sqlite::finalize(all);
    guard endings.len > 1 else { return 0; }
    let known = prepare_or_die(db, "SELECT 1 FROM files WHERE file = ?1");
    var n: i64 = 0;
    each_file(fresh_root[..fresh_root.len - 1]) { full, name =>
        let e = file_ending(name);
        if e.len > 0 && find(endings, str("\n", e, "\n")) >= 0 && swan_mtime_ns(full) > fresh_scip_time {
            let rel = full[fresh_root.len..];
            sqlite::bind_text(known, 1, rel);
            let mapped = sqlite::step(known, err) == 1;
            sqlite::reset(known);
            if !mapped {
                out.append(rel);
                out.push('\n');
                n++;
            }
        }
    };
    sqlite::finalize(known);
    return n;
}

// ".ts" for "src/a.ts": from the last dot of the last path part, or "" when
// that part has no dot (or only a leading one, as in ".gitignore").
fn file_ending(path: u8[:]) -> u8[:] {
    let slash = rfind(path, "/");
    let base = if slash >= 0 { path[slash + 1..] } else { path };
    let dot = rfind(base, ".");
    return if dot > 0 { base[dot..] } else { base[0..0] };
}

// When the SCIP run started: the marker `swan map` leaves, or else
// index.scip beside the rows, or the rows themselves.
fn scip_time_of(dir: const u8[:]) -> i64 {
    let started = swan_mtime_ns(str(dir, "/scip-started"));
    if started > 0 { return started; }
    let t = swan_mtime_ns(str(dir, "/index.scip"));
    return if t > 0 { t } else { swan_mtime_ns(str(dir, "/occurrences.tsv")) };
}
