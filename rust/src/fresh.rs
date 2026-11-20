// Freshness: whether a file changed after the SCIP run the map was built
// from. Answers about such a file may be out of date, and each one says so
// with "stale": true, so an agent knows to reread the file or refresh the
// map. The check is one stat per file: modified after the SCIP run, or gone.
// A file Swan edited itself is not stale: Swan shifted its rows to match
// (stage 6, edit) and recorded the mtime it left, so only a later outside
// change makes it stale again.
//
// Carried over from src/fresh.goose. What were that file's three globals
// are this struct, made for the connection that answers.

use crate::db::{Db, Stmt};
use crate::query::meta_value;
use crate::sys;
use crate::util::{find, hash, parse_int, rfind};
use crate::walk::Walk;

pub struct Fresh {
    root: Vec<u8>,   // the repo, with a '/' at its end; empty when unknown
    scip_time: i64,  // ns since the epoch; 0 when unknown
    edited: Stmt,    // a file's edited_mtime
    pub walk: Walk,  // what git ignores there
}

impl Fresh {
    // Loads the map's root and SCIP time for `db`, the connection the server
    // answers from. Reloaded each request: another process may have refreshed
    // or replaced the map. Swan's own edit mtimes are persisted in files.
    pub fn load(db: &Db) -> Fresh {
        let mut root: Vec<u8> = Vec::new();
        let mut walk = Walk::default();
        let v = meta_value(db, b"root");
        if !v.is_empty() && v.len() < 4000 {
            root.extend_from_slice(&v);
            if v[v.len() - 1] != b'/' {
                root.push(b'/');
            }
            // What git ignores there, for every walk this process makes of the
            // repo (new files, structural search): kept in the map's folder.
            let src = meta_value(db, b"source");
            if !src.is_empty() {
                walk.load(if v[v.len() - 1] == b'/' { &v[..v.len() - 1] } else { &v[..] }, &src);
            }
        }
        let scip_time = parse_int(&meta_value(db, b"scip_time")).unwrap_or(0);
        let edited = db.prepare_or_die(b"SELECT edited_mtime, hash FROM files WHERE file = ?1");
        Fresh { root, scip_time, edited, walk }
    }

    // The mtime Swan left on a file it edited, or -1; mark gets what it stored
    // for the text it left ("" in a map written before Swan stored one).
    fn edited_mtime(&self, file: &[u8], mark: &mut Vec<u8>) -> i64 {
        mark.clear();
        let mut t = -1;
        self.edited.bind_text(1, file);
        if self.edited.step_checked() {
            let v = self.edited.col_text(0);
            if !v.is_empty() {
                t = self.edited.col_int(0);
                *mark = self.edited.col_text(1);
            }
        }
        self.edited.reset();
        t
    }

    pub fn is_stale(&self, file: &[u8]) -> bool {
        if !(self.scip_time > 0 && !self.root.is_empty() && !file.is_empty()) {
            return false;
        }
        let p = [&self.root[..], file].concat();
        let m = sys::mtime_ns(&p);
        if m < 0 {
            return true;
        }
        if m <= self.scip_time {
            return false;
        }
        // Changed since the SCIP run: fresh only if it is still what Swan's own
        // edit left. Same mtime, and the same text: another write in the same
        // clock tick keeps the mtime (found 2026-11-17 on a 6.1 kernel, where
        // six writes in a row shared one).
        let mut mark: Vec<u8> = Vec::new();
        if m != self.edited_mtime(file, &mut mark) {
            return true;
        }
        if !(mark.len() > 1 && mark[0] == b'e') {
            return false;
        }
        let mut text: Vec<u8> = Vec::new();
        if !sys::read_file(&p, &mut text) {
            return true;
        }
        edit_mark(&text) != mark
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
    pub fn new_files(&self, db: &Db, out: &mut Vec<u8>) -> i64 {
        if !(self.scip_time > 0 && self.root.len() > 1) {
            return 0;
        }
        let mut endings: Vec<u8> = vec![b'\n']; // "\n.ts\n.py\n"
        let has = |endings: &[u8], e: &[u8]| find(endings, &[b"\n", e, b"\n"].concat()) >= 0;
        // Only files with rows: mark_edited (stage 6, edit) adds an empty row
        // for any file Swan edits or formats, which must not add its ending.
        let all = db.prepare_or_die(b"SELECT file FROM files WHERE rows > 0");
        while all.step_checked() {
            let f = all.col_text(0);
            let e = file_ending(&f);
            if !e.is_empty() && !has(&endings, e) {
                endings.extend_from_slice(e);
                endings.push(b'\n');
            }
        }
        drop(all);
        if endings.len() <= 1 {
            return 0;
        }
        let known = db.prepare_or_die(b"SELECT 1 FROM files WHERE file = ?1");
        let mut n: i64 = 0;
        self.walk.each_file(&self.root[..self.root.len() - 1], |full, name| {
            let e = file_ending(name);
            if !e.is_empty() && has(&endings, e) && sys::mtime_ns(full) > self.scip_time {
                let rel = &full[self.root.len()..];
                known.bind_text(1, rel);
                let mapped = known.step_checked();
                known.reset();
                if !mapped {
                    out.extend_from_slice(rel);
                    out.push(b'\n');
                    n += 1;
                }
            }
        });
        n
    }
}

// What mark_edited stores for the text Swan left in a file.
pub fn edit_mark(text: &[u8]) -> Vec<u8> {
    format!("e{}", hash(text)).into_bytes()
}

// ".ts" for "src/a.ts": from the last dot of the last path part, or "" when
// that part has no dot (or only a leading one, as in ".gitignore").
pub fn file_ending(path: &[u8]) -> &[u8] {
    let slash = rfind(path, b"/");
    let base = if slash >= 0 { &path[slash as usize + 1..] } else { path };
    let dot = rfind(base, b".");
    if dot > 0 {
        &base[dot as usize..]
    } else {
        &base[0..0]
    }
}

// When the SCIP run started: the marker `swan map` leaves, or else
// index.scip beside the rows, or the rows themselves.
pub fn scip_time_of(dir: &[u8]) -> i64 {
    let started = sys::mtime_ns(&[dir, b"/scip-started"].concat());
    if started > 0 {
        return started;
    }
    let t = sys::mtime_ns(&[dir, b"/index.scip"].concat());
    if t > 0 {
        t
    } else {
        sys::mtime_ns(&[dir, b"/occurrences.tsv"].concat())
    }
}
