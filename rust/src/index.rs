// `swan index` and `swan refresh`: build or update the code map from the
// flattened SCIP rows (bin/swan-flatten) in SQLite. This program does the map
// work: it interns symbols, parses their names and kinds, and finds the
// symbol each reference sits inside. SQLite stores the result and answers
// queries.
//
// Both commands take the same input: the rows of a whole SCIP run, which is
// the only kind scip-typescript makes. Each file's rows are fingerprinted.
// `index` writes every file into a new database beside its final path and
// renames it over, so a reader never sees half an index. `refresh` compares
// fingerprints with the ones stored and rewrites only the files whose rows
// changed, in one transaction. A file's rows change when the file was edited
// and also when an edit elsewhere changed how it resolves (a rename, a moved
// export), so this stays exact. Which symbol a reference sits inside depends
// only on its own file's definitions, so unchanged files need no rework.
//
// Carried over from src/index.goose.

use crate::db::{Db, Stmt};
use crate::fresh::scip_time_of;
use crate::query::meta_value;
use crate::scip::{describe, kind_word, language_of};
use crate::sys;
use crate::util::{die, hash, hash_combine, parse_int, tsv_rows, push_int, split, Dict, TextMap, TextSet};

pub const SCHEMA_VERSION: i64 = 9;

// Kept byte for byte: SQLite stores each statement's text in the map.
const SCHEMA: &str = r#"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE files (
    file TEXT PRIMARY KEY,
    hash TEXT NOT NULL,
    rows INTEGER NOT NULL,
    edited_mtime INTEGER       -- set when Swan edited the file and shifted its rows itself
);
CREATE TABLE symbols (
    id INTEGER PRIMARY KEY,
    scip TEXT NOT NULL,
    name TEXT NOT NULL,
    name_path TEXT NOT NULL,
    kind TEXT NOT NULL,
    signature TEXT NOT NULL,
    doc TEXT,                        -- the documentation's prose, code blocks taken out
    def_file TEXT,
    def_line INTEGER,
    def_col INTEGER,
    body_start INTEGER,
    body_end INTEGER,
    body_start_col INTEGER,
    body_end_col INTEGER,
    in_repo INTEGER NOT NULL,
    language TEXT NOT NULL
);
CREATE UNIQUE INDEX symbols_scip ON symbols (scip);
CREATE TABLE relationships (
    symbol_id INTEGER NOT NULL,      -- implements, overrides or is typed as ...
    related_id INTEGER NOT NULL,     -- ... this one
    file TEXT NOT NULL,              -- where symbol_id is defined
    is_impl INTEGER NOT NULL,
    is_ref INTEGER NOT NULL,
    is_typedef INTEGER NOT NULL,
    is_def INTEGER NOT NULL
);
CREATE TABLE occurrences (
    symbol_id INTEGER NOT NULL,
    file TEXT NOT NULL,
    start_line INTEGER NOT NULL,
    start_col INTEGER NOT NULL,
    end_line INTEGER NOT NULL,
    end_col INTEGER NOT NULL,
    is_def INTEGER NOT NULL,
    enclosing_id INTEGER,
    by_name INTEGER NOT NULL DEFAULT 0,  -- matched by name in a macro call, not resolved
    is_import INTEGER NOT NULL DEFAULT 0 -- the name in an import statement
);
"#;

// Created after a full build's bulk load, which is faster than keeping them
// up to date row by row.
const INDEXES: &str = r#"CREATE INDEX symbols_name ON symbols (name);
CREATE INDEX symbols_name_path ON symbols (name_path);
CREATE INDEX symbols_def_file ON symbols (def_file);
CREATE INDEX occurrences_symbol ON occurrences (symbol_id, is_def);
CREATE INDEX occurrences_file ON occurrences (file, start_line);
CREATE INDEX occurrences_enclosing ON occurrences (enclosing_id);
CREATE INDEX relationships_symbol ON relationships (symbol_id);
CREATE INDEX relationships_related ON relationships (related_id);
CREATE INDEX relationships_file ON relationships (file);
"#;

// From symbols.tsv.
struct SymMeta<'a> {
    sig: &'a [u8],
    doc: &'a [u8],
    kind: i64,
}

struct Sym<'a> {
    scip: &'a [u8],
    db_id: i64,
    def_file: &'a [u8],
    line: i64, // the definition's name
    col: i64,
    body_start: i64, // its whole span, -1 if SCIP gave none
    body_end: i64,
    body_start_col: i64,
    body_end_col: i64,
    has_def: bool,
    touched: bool, // its row needs writing
}

struct Ext {
    id: i64,
    sl: i64,
    sc: i64,
    el: i64,
    ec: i64,
}

// A file's run of extents.
struct Span {
    lo: usize,
    hi: usize,
}

pub fn field_int(s: &[u8]) -> i64 {
    match parse_int(s) {
        Some(v) => v,
        None => die(&[b"swan index: not a number: '", s, b"'"].concat()),
    }
}

// A row with fewer fields than its table has is refused (the Goose program
// stops on it too, at the field that is not there).
fn need(have: usize, want: usize, line: &[u8]) {
    if have < want {
        die(&[b"swan index: a row with too few fields: '", line, b"'"].concat());
    }
}

fn int_text(v: i64) -> Vec<u8> {
    v.to_string().into_bytes()
}

// Symbols: found in this run's rows first, then in the database, and
// otherwise added. A symbol keeps its id across refreshes.
struct Interner<'a, 'b> {
    ids: TextMap<&'a [u8], usize>,
    syms: Vec<Sym<'a>>,
    sigs: &'b TextMap<&'a [u8], SymMeta<'a>>,
    find_sym: Stmt,
    add_sym: Stmt,
}

impl<'a, 'b> Interner<'a, 'b> {
    fn intern(&mut self, scip: &'a [u8]) -> usize {
        if let Some(&got) = self.ids.get(scip) {
            return got;
        }
        let mut db_id = -1;
        self.find_sym.bind_text(1, scip);
        if self.find_sym.step_checked() {
            db_id = self.find_sym.col_int(0);
        }
        self.find_sym.reset();
        if db_id < 0 {
            let mut path: Vec<u8> = Vec::new();
            let (name, suffix, parent) = describe(scip, &mut path);
            let m = self.sigs.get(scip);
            let s: &[u8] = match m {
                Some(m) => m.sig,
                None => &scip[0..0],
            };
            let sk = match m {
                Some(m) => m.kind,
                None => 0,
            };
            self.add_sym.bind_text(1, scip);
            self.add_sym.bind_text(2, name);
            self.add_sym.bind_text(3, &path);
            self.add_sym.bind_text(4, kind_word(s, suffix, parent, sk));
            self.add_sym.bind_text(5, s);
            self.add_sym.bind_text(6, language_of(scip));
            match self.add_sym.step() {
                Ok(true) => {}
                Ok(false) => die(b"sqlite: "),
                Err(e) => die(&[b"sqlite: ", &e[..]].concat()),
            }
            db_id = self.add_sym.col_int(0);
            self.add_sym.reset();
        }
        let k = self.syms.len();
        self.syms.push(Sym {
            scip,
            db_id,
            def_file: &scip[0..0],
            line: -1,
            col: -1,
            body_start: -1,
            body_end: -1,
            body_start_col: -1,
            body_end_col: -1,
            has_def: false,
            touched: false,
        });
        self.ids.insert(scip, k);
        k
    }
}

// The smallest extent in the file that holds the position, or -1.
fn enclosing(runs: &TextMap<&[u8], Span>, exts: &[Ext], file: &[u8], line: i64, col: i64) -> i64 {
    let r = match runs.get(file) {
        Some(r) => r,
        None => return -1,
    };
    let mut best = -1;
    let mut best_size = 0;
    for e in &exts[r.lo..r.hi] {
        let after_start = line > e.sl || (line == e.sl && col >= e.sc);
        let before_end = line < e.el || (line == e.el && col <= e.ec);
        if after_start && before_end {
            let size = (e.el - e.sl) * 100000 + (e.ec - e.sc);
            if best < 0 || size < best_size {
                best = e.id;
                best_size = size;
            }
        }
    }
    best
}

// Appends a one-line account of what it did to `report`.
pub fn index_main(dir: &[u8], db_path: &[u8], root: &[u8], refresh: bool, report: &mut Vec<u8>) {
    let writer = match sys::WriterLock::acquire(db_path) {
        Ok(w) => w,
        Err(e) => die(&e),
    };
    index_main_locked(dir, db_path, root, refresh, report);
    writer.complete();
}

// map_main already owns this database's writer lock across indexer output and
// flattening, so it enters here without trying to acquire that lock again.
pub fn index_main_locked(dir: &[u8], db_path: &[u8], root: &[u8], refresh: bool, report: &mut Vec<u8>) {
    let t0 = std::time::Instant::now();
    let in_dir = |name: &[u8]| [dir, b"/", name].concat();
    let mut text: Vec<u8> = Vec::new();
    let a = text.len();
    if !sys::read_file(&in_dir(b"symbols.tsv"), &mut text) {
        die(&[b"cannot read ", dir, b"/symbols.tsv"].concat());
    }
    let b = text.len();
    if !sys::read_file(&in_dir(b"extents.tsv"), &mut text) {
        die(&[b"cannot read ", dir, b"/extents.tsv"].concat());
    }
    let c = text.len();
    // Optional: rows flattened before relationships existed have none.
    sys::read_file(&in_dir(b"relationships.tsv"), &mut text);
    let r = text.len();
    if !sys::read_file(&in_dir(b"occurrences.tsv"), &mut text) {
        die(&[b"cannot read ", dir, b"/occurrences.tsv"].concat());
    }
    let d = text.len();
    let text = &text[..];

    // symbols.tsv: symbol, display_name, kind, enclosing_symbol, signature/doc line
    let mut sigs: TextMap<&[u8], SymMeta> = TextMap::default();
    for (it, f, nf) in tsv_rows(&text[a..b]) {
        if it.is_empty() {
            continue;
        }
        let mut kind = 0;
        if nf > 2 {
            if let Some(k) = parse_int(f[2]) {
                kind = k;
            }
        }
        sigs.insert(
            f[0],
            SymMeta {
                sig: if nf > 4 { f[4] } else { &f[0][0..0] },
                doc: if nf > 5 { f[5] } else { &f[0][0..0] },
                kind,
            },
        );
    }

    // Each file's fingerprint: its extent and occurrence rows, in order, and
    // what symbols.tsv says of the symbols it defines (an edited doc comment
    // or signature can leave every row as it was).
    let mut hashes: Dict<u64> = Dict::new();
    let mut rows: TextMap<&[u8], i64> = TextMap::default();
    for (line, f, nf) in tsv_rows(&text[b..d]) {
        if line.is_empty() {
            continue;
        }
        need(nf, 2, line);
        let h = hashes.entry(f[1], 0);
        *h = hash_combine(*h, hash(line));
        if nf == 7 && f[6] == b"def" {
            if let Some(m) = sigs.get(f[0]) {
                let mut s = int_text(m.kind);
                s.push(b'\t');
                s.extend_from_slice(m.sig);
                s.push(b'\t');
                s.extend_from_slice(m.doc);
                let h = hashes.entry(f[1], 0);
                *h = hash_combine(*h, hash(&s));
            }
        }
        *rows.entry(f[1]).or_insert(0) += 1;
    }

    // The database: a new one beside its final name, or the existing one.
    let tmp = [db_path, b".tmp"].concat();
    let path: &[u8] = if refresh { db_path } else { &tmp };
    if !refresh && sys::file_exists(&tmp) {
        sys::delete_file(&tmp);
    }
    if refresh && !sys::file_exists(db_path) {
        die(&[b"swan refresh: no index at ", db_path, b"; run swan index first"].concat());
    }
    let opened = if refresh { Db::open_existing(path) } else { Db::open(path) };
    let db = match opened {
        Ok(db) => db,
        Err(e) => die(&[b"swan: cannot open ", path, b": ", &e[..]].concat()),
    };
    if refresh {
        let version = meta_value(&db, b"schema_version");
        if version != int_text(SCHEMA_VERSION) {
            die(&[
                b"swan refresh: index schema ",
                &version[..],
                b", this swan writes ",
                &int_text(SCHEMA_VERSION)[..],
                b"; rebuild it with swan index",
            ]
            .concat());
        }
        db.exec_or_die(b"BEGIN;");
    } else {
        db.exec_or_die(b"PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA cache_size = -262144; PRAGMA temp_store = MEMORY; PRAGMA locking_mode = EXCLUSIVE;");
        db.exec_or_die(SCHEMA.as_bytes());
        db.exec_or_die(b"BEGIN;");
    }

    // Which files to rewrite: those whose fingerprint differs from the stored
    // one (all of them in a new database), and those no longer in the rows.
    let mut changed: TextSet<&[u8]> = TextSet::default();
    let get_hash = db.prepare_or_die(b"SELECT hash FROM files WHERE file = ?1");
    let put_file = db.prepare_or_die(b"INSERT OR REPLACE INTO files (file, hash, rows) VALUES (?1, ?2, ?3)");
    let drop_occ = db.prepare_or_die(b"DELETE FROM occurrences WHERE file = ?1");
    let drop_rel = db.prepare_or_die(b"DELETE FROM relationships WHERE file = ?1");
    let reset_defs = db.prepare_or_die(
        b"UPDATE symbols SET def_file = NULL, def_line = NULL, def_col = NULL,
                   body_start = NULL, body_end = NULL, body_start_col = NULL, body_end_col = NULL, in_repo = 0
WHERE def_file = ?1
",
    );
    db.exec_or_die(b"CREATE TEMP TABLE seen (file TEXT PRIMARY KEY);");
    let put_seen = db.prepare_or_die(b"INSERT INTO temp.seen VALUES (?1)");
    for (file, h) in hashes.each() {
        let fp = h.to_string().into_bytes();
        put_seen.bind_text(1, file);
        put_seen.step_done();
        let mut stored: Vec<u8> = Vec::new();
        get_hash.bind_text(1, file);
        if get_hash.step_checked() {
            stored = get_hash.col_text(0);
        }
        get_hash.reset();
        if stored != fp {
            changed.insert(file);
            if refresh {
                drop_occ.bind_text(1, file);
                drop_occ.step_done();
                drop_rel.bind_text(1, file);
                drop_rel.step_done();
                reset_defs.bind_text(1, file);
                reset_defs.step_done();
            }
            put_file.bind_text(1, file);
            put_file.bind_text(2, &fp);
            put_file.bind_int(3, rows.get(file).copied().unwrap_or(0));
            put_file.step_done();
        }
    }
    let mut removed = 0;
    if refresh {
        let gone = db.prepare_or_die(b"SELECT count(*) FROM files WHERE file NOT IN (SELECT file FROM temp.seen)");
        if gone.step_checked() {
            removed = gone.col_int(0);
        }
        drop(gone);
        db.exec_or_die(
            b"DELETE FROM occurrences WHERE file NOT IN (SELECT file FROM temp.seen);
DELETE FROM relationships WHERE file NOT IN (SELECT file FROM temp.seen);
UPDATE symbols SET def_file = NULL, def_line = NULL, def_col = NULL,
                   body_start = NULL, body_end = NULL, body_start_col = NULL, body_end_col = NULL, in_repo = 0
WHERE def_file NOT IN (SELECT file FROM temp.seen);
DELETE FROM files WHERE file NOT IN (SELECT file FROM temp.seen);
",
        );
    }
    drop(get_hash);
    drop(put_file);
    drop(drop_occ);
    drop(drop_rel);
    drop(reset_defs);
    drop(put_seen);

    let mut it = Interner {
        ids: TextMap::default(),
        syms: Vec::new(),
        sigs: &sigs,
        find_sym: db.prepare_or_die(b"SELECT id FROM symbols WHERE scip = ?1"),
        add_sym: db.prepare_or_die(
            b"INSERT INTO symbols (scip, name, name_path, kind, signature, in_repo, language)
VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6) RETURNING id
",
        ),
    };

    // extents.tsv: symbol, file, start_line, start_col, end_line, end_col, in
    // document order, so each file's extents are one run.
    let mut exts: Vec<Ext> = Vec::new();
    let mut runs: TextMap<&[u8], Span> = TextMap::default();
    for (line, f, nf) in tsv_rows(&text[b..c]) {
        if line.is_empty() {
            continue;
        }
        if !changed.contains(f[1]) {
            continue;
        }
        need(nf, 6, line);
        let k = it.intern(f[0]);
        let e = Ext { id: it.syms[k].db_id, sl: field_int(f[2]), sc: field_int(f[3]), el: field_int(f[4]), ec: field_int(f[5]) };
        let s = &mut it.syms[k];
        s.body_start = e.sl;
        s.body_end = e.el;
        s.body_start_col = e.sc;
        s.body_end_col = e.ec;
        s.touched = true;
        let at = exts.len();
        runs.entry(f[1]).or_insert(Span { lo: at, hi: at }).hi = at + 1;
        exts.push(e);
    }

    // occurrences.tsv: symbol, file, start_line, start_col, end_line, end_col, def|ref
    let ins_occ = db.prepare_or_die(b"INSERT INTO occurrences VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)");
    let mut occ_count: i64 = 0;
    for (line, f, nf) in tsv_rows(&text[r..d]) {
        if line.is_empty() {
            continue;
        }
        if !changed.contains(f[1]) {
            continue;
        }
        need(nf, 7, line);
        let k = it.intern(f[0]);
        let sl = field_int(f[2]);
        let sc = field_int(f[3]);
        let is_def = f[6] == b"def";
        let s = &mut it.syms[k];
        if is_def && !s.has_def {
            s.has_def = true;
            s.touched = true;
            s.def_file = f[1];
            s.line = sl;
            s.col = sc;
        }
        ins_occ.bind_int(1, s.db_id);
        ins_occ.bind_text(2, f[1]);
        ins_occ.bind_int(3, sl);
        ins_occ.bind_int(4, sc);
        ins_occ.bind_int(5, field_int(f[4]));
        ins_occ.bind_int(6, field_int(f[5]));
        ins_occ.bind_int(7, if is_def { 1 } else { 0 });
        ins_occ.bind_int(9, if f[6] == b"name" { 1 } else { 0 });
        ins_occ.bind_int(10, if f[6] == b"imp" { 1 } else { 0 });
        if !is_def {
            let enc = enclosing(&runs, &exts, f[1], sl, sc);
            if enc >= 0 {
                ins_occ.bind_int(8, enc);
            }
        }
        ins_occ.step_done();
        occ_count += 1;
    }
    drop(ins_occ);

    // relationships.tsv: symbol, file, related_symbol, flags (impl,ref,type,def)
    let ins_rel = db.prepare_or_die(b"INSERT INTO relationships VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    let mut rel_count: i64 = 0;
    for (line, f, nf) in tsv_rows(&text[c..r]) {
        if line.is_empty() {
            continue;
        }
        if !(nf >= 4 && changed.contains(f[1])) {
            continue;
        }
        let k = it.intern(f[0]);
        let j = it.intern(f[2]);
        let flags = split(f[3], b',');
        let has = |w: &[u8]| if flags.contains(&w) { 1 } else { 0 };
        ins_rel.bind_int(1, it.syms[k].db_id);
        ins_rel.bind_int(2, it.syms[j].db_id);
        ins_rel.bind_text(3, f[1]);
        ins_rel.bind_int(4, has(b"impl"));
        ins_rel.bind_int(5, has(b"ref"));
        ins_rel.bind_int(6, has(b"type"));
        ins_rel.bind_int(7, has(b"def"));
        ins_rel.step_done();
        rel_count += 1;
    }
    drop(ins_rel);
    // The interner's two statements are let go here. Taking `syms` alone
    // out of it would leave them alive to the end of this function: a map
    // closed with a statement still open stays open, and a new map is
    // written under an exclusive lock, so nothing later in this process
    // could read it (the end of `swan map` reads it for the crates with no
    // rows).
    let Interner { syms, find_sym, add_sym, .. } = it;
    drop(find_sym);
    drop(add_sym);

    // The definitions found in rewritten files, and their current signatures.
    let upd_sym = db.prepare_or_die(
        b"UPDATE symbols SET kind = ?2, signature = ?3, doc = ?12, def_file = ?4, def_line = ?5, def_col = ?6,
                   body_start = ?7, body_end = ?8, in_repo = ?9,
                   body_start_col = ?10, body_end_col = ?11
WHERE id = ?1
",
    );
    for s in &syms {
        if !s.touched {
            continue;
        }
        let mut path: Vec<u8> = Vec::new();
        let (_name, suffix, parent) = describe(s.scip, &mut path);
        let m = sigs.get(s.scip);
        let sg: &[u8] = match m {
            Some(m) => m.sig,
            None => &s.scip[0..0],
        };
        let sk = match m {
            Some(m) => m.kind,
            None => 0,
        };
        upd_sym.bind_int(1, s.db_id);
        upd_sym.bind_text(2, kind_word(sg, suffix, parent, sk));
        upd_sym.bind_text(3, sg);
        if let Some(m) = m {
            if !m.doc.is_empty() {
                upd_sym.bind_text(12, m.doc);
            }
        }
        if s.has_def {
            upd_sym.bind_text(4, s.def_file);
            upd_sym.bind_int(5, s.line);
            upd_sym.bind_int(6, s.col);
        }
        if s.body_start >= 0 {
            upd_sym.bind_int(7, s.body_start);
            upd_sym.bind_int(8, s.body_end);
            upd_sym.bind_int(10, s.body_start_col);
            upd_sym.bind_int(11, s.body_end_col);
        }
        upd_sym.bind_int(9, if s.has_def { 1 } else { 0 });
        upd_sym.step_done();
    }
    drop(upd_sym);

    // A symbol nothing mentions any more goes.
    if refresh {
        db.exec_or_die(b"DELETE FROM symbols WHERE in_repo = 0 AND id NOT IN (SELECT symbol_id FROM occurrences) AND id NOT IN (SELECT related_id FROM relationships);");
    }

    let ins_meta = db.prepare_or_die(b"INSERT OR REPLACE INTO meta VALUES (?1, ?2)");
    let meta = |key: &[u8], value: &[u8]| {
        ins_meta.bind_text(1, key);
        ins_meta.bind_text(2, value);
        ins_meta.step_done();
    };
    let cnt = db.prepare_or_die(b"SELECT (SELECT count(*) FROM symbols), (SELECT count(*) FROM occurrences)");
    let mut n_syms = 0;
    let mut n_occ = 0;
    if cnt.step_checked() {
        n_syms = cnt.col_int(0);
        n_occ = cnt.col_int(1);
    }
    drop(cnt);
    // Seconds since the epoch, as Goose's str(time()) writes them.
    let now = format!("{}", sys::time_ns() as f64 / 1000000000.0).into_bytes();
    meta(b"schema_version", &int_text(SCHEMA_VERSION));
    if !refresh || !root.is_empty() {
        meta(b"root", root);
    }
    meta(b"source", dir);
    meta(b"scip_time", &int_text(scip_time_of(dir)));
    if refresh {
        meta(b"refreshed_at", &now);
    } else {
        meta(b"built_at", &now);
    }
    meta(b"symbols", &int_text(n_syms));
    meta(b"occurrences", &int_text(n_occ));
    meta(b"files", &int_text(hashes.count));
    drop(ins_meta);

    // scip-java names Kotlin symbols like Java ones; the file says which.
    db.exec_or_die(b"UPDATE symbols SET language = 'kotlin' WHERE language = 'java' AND (def_file LIKE '%.kt' OR def_file LIKE '%.kts');");
    db.exec_or_die(b"COMMIT;");
    if !refresh {
        db.exec_or_die(INDEXES.as_bytes());
    }
    drop(db);
    if !refresh && !sys::rename_file(&tmp, db_path) {
        die(&[b"swan index: cannot rename ", &tmp[..], b" to ", db_path].concat());
    }
    report.extend_from_slice(if refresh { b"swan refresh: " } else { b"swan index: " });
    push_int(report, changed.len() as i64);
    report.extend_from_slice(b" of ");
    push_int(report, hashes.count);
    report.extend_from_slice(b" files rewritten");
    if removed > 0 {
        report.extend_from_slice(b", ");
        push_int(report, removed);
        report.extend_from_slice(b" removed");
    }
    report.extend_from_slice(b"; ");
    push_int(report, occ_count);
    report.extend_from_slice(b" occurrences and ");
    push_int(report, rel_count);
    report.extend_from_slice(b" relationships written; map has ");
    push_int(report, n_syms);
    report.extend_from_slice(b" symbols, ");
    push_int(report, n_occ);
    report.extend_from_slice(b" occurrences -> ");
    report.extend_from_slice(db_path);
    report.extend_from_slice(b" in ");
    push_int(report, (t0.elapsed().as_secs_f64() * 1000.0) as i64);
    report.extend_from_slice(b" ms");
}
