// `swan index` and `swan refresh`: build or update the code map from the
// flattened SCIP rows (tools/scip-flatten.ts) in SQLite. Goose does the map
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

import std;
import os;
import dictionary;
import sqlite;

let SCHEMA_VERSION = 9;

let SCHEMA = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
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
    """;

// Created after a full build's bulk load, which is faster than keeping them
// up to date row by row.
let INDEXES = """
    CREATE INDEX symbols_name ON symbols (name);
    CREATE INDEX symbols_name_path ON symbols (name_path);
    CREATE INDEX symbols_def_file ON symbols (def_file);
    CREATE INDEX occurrences_symbol ON occurrences (symbol_id, is_def);
    CREATE INDEX occurrences_file ON occurrences (file, start_line);
    CREATE INDEX occurrences_enclosing ON occurrences (enclosing_id);
    CREATE INDEX relationships_symbol ON relationships (symbol_id);
    CREATE INDEX relationships_related ON relationships (related_id);
    CREATE INDEX relationships_file ON relationships (file);
    """;

struct SymMeta { sig: const u8[:], doc: const u8[:], kind: i64 }   // from symbols.tsv

struct Sym {
    db_id: i64,
    def_file: const u8[:],
    line: i64, col: i64,             // the definition's name
    body_start: i64, body_end: i64,  // its whole span, -1 if SCIP gave none
    body_start_col: i64, body_end_col: i64,
    has_def: bool,
    touched: bool,                   // its row needs writing
}

struct Ext { id: i64, sl: i64, sc: i64, el: i64, ec: i64 }

struct Span { lo: i64, hi: i64 }    // a file's run of extents

fn field_int(s: const u8[:]) -> i64 {
    let v, ok = parse_int(s);
    if !ok { abort(str("swan index: not a number: '", s, "'")); }
    return v;
}

// Appends a one-line account of what it did to `report`.
fn index_main(dir: const u8[:], db_path: const u8[:], root: const u8[:], refresh: bool, report: u8[>..]&) {
    let t0 = clock();
    var text: u8[>..] = [];
    let a = text.len;
    guard read_file(str(dir, "/symbols.tsv"), text) else { abort(str("cannot read ", dir, "/symbols.tsv")); }
    let b = text.len;
    guard read_file(str(dir, "/extents.tsv"), text) else { abort(str("cannot read ", dir, "/extents.tsv")); }
    let c = text.len;
    // Optional: rows flattened before relationships existed have none.
    read_file(str(dir, "/relationships.tsv"), text);
    let r = text.len;
    guard read_file(str(dir, "/occurrences.tsv"), text) else { abort(str("cannot read ", dir, "/occurrences.tsv")); }
    let d = text.len;

    // symbols.tsv: symbol, display_name, kind, enclosing_symbol, signature/doc line
    var sigs = dictionary<const u8[:], SymMeta> {};
    each_split(text[a..b], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        var kind = 0;
        if f.len > 2 { let k, ok = parse_int(f[2]); if ok { kind = k; } }
        sigs.insert(f[0], SymMeta { sig: if f.len > 4 { f[4] } else { f[0][0..0] },
                                    doc: if f.len > 5 { f[5] } else { f[0][0..0] }, kind: kind });
    };

    // Each file's fingerprint: its extent and occurrence rows, in order, and
    // what symbols.tsv says of the symbols it defines (an edited doc comment
    // or signature can leave every row as it was).
    var hashes = dictionary<const u8[:], u64> {};
    var rows = dictionary<const u8[:], i64> {};
    each_split(text[b..d], '\n') { line =>
        guard line.len > 0;
        let f = split(line, '\t');
        hashes.update(f[1], 0) { h => h = hash_combine(h, hash(line)); };
        if f.len == 7 && f[6] == "def" {
            let m = sigs.get(f[0]);
            if m { hashes.update(f[1], 0) { h => h = hash_combine(h, hash(str(m.kind, "\t", m.sig, "\t", m.doc))); }; }
        }
        rows.update(f[1], 0) { n => n += 1; };
    };

    // The database: a new one beside its final name, or the existing one.
    let tmp = str(db_path, ".tmp");
    let path = if refresh { db_path } else { tmp };
    if !refresh && file_exists(tmp) { delete_file(tmp); }
    if refresh && !file_exists(db_path) { abort(str("swan refresh: no index at ", db_path, "; run swan index first")); }
    var err: u8[>..] = [];
    let db = sqlite::open(path, err);
    if db == 0 { abort(str("swan: cannot open ", path, ": ", err)); }
    if refresh {
        var version: u8[>..] = [];
        meta_value(db, "schema_version", version);
        if version != str(SCHEMA_VERSION) {
            abort(str("swan refresh: index schema ", version, ", this swan writes ", SCHEMA_VERSION,
                      "; rebuild it with swan index"));
        }
        exec_or_die(db, "BEGIN;");
    } else {
        exec_or_die(db, "PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA cache_size = -262144; PRAGMA temp_store = MEMORY; PRAGMA locking_mode = EXCLUSIVE;");
        exec_or_die(db, SCHEMA);
        exec_or_die(db, "BEGIN;");
    }

    // Which files to rewrite: those whose fingerprint differs from the stored
    // one (all of them in a new database), and those no longer in the rows.
    var changed = dictionary<const u8[:], bool> {};
    let get_hash = prepare_or_die(db, "SELECT hash FROM files WHERE file = ?1");
    let put_file = prepare_or_die(db, "INSERT OR REPLACE INTO files (file, hash, rows) VALUES (?1, ?2, ?3)");
    let drop_occ = prepare_or_die(db, "DELETE FROM occurrences WHERE file = ?1");
    let drop_rel = prepare_or_die(db, "DELETE FROM relationships WHERE file = ?1");
    let reset_defs = prepare_or_die(db, """
        UPDATE symbols SET def_file = NULL, def_line = NULL, def_col = NULL,
                           body_start = NULL, body_end = NULL, body_start_col = NULL, body_end_col = NULL, in_repo = 0
        WHERE def_file = ?1
        """);
    exec_or_die(db, "CREATE TEMP TABLE seen (file TEXT PRIMARY KEY);");
    let put_seen = prepare_or_die(db, "INSERT INTO temp.seen VALUES (?1)");
    hashes.each() { file, h =>
        let fp = str(h);
        sqlite::bind_text(put_seen, 1, file);
        step_done(put_seen);
        var stored: u8[>..] = [];
        sqlite::bind_text(get_hash, 1, file);
        if sqlite::step(get_hash, err) == 1 { sqlite::col_text(get_hash, 0, stored); }
        sqlite::reset(get_hash);
        if stored != fp {
            changed.insert(file, true);
            if refresh {
                sqlite::bind_text(drop_occ, 1, file);
                step_done(drop_occ);
                sqlite::bind_text(drop_rel, 1, file);
                step_done(drop_rel);
                sqlite::bind_text(reset_defs, 1, file);
                step_done(reset_defs);
            }
            sqlite::bind_text(put_file, 1, file);
            sqlite::bind_text(put_file, 2, fp);
            let n = rows.get(file);
            sqlite::bind_int(put_file, 3, if n { n } else { 0 });
            step_done(put_file);
        }
    };
    var removed = 0;
    if refresh {
        let gone = prepare_or_die(db, "SELECT count(*) FROM files WHERE file NOT IN (SELECT file FROM temp.seen)");
        if sqlite::step(gone, err) == 1 { removed = sqlite::col_int(gone, 0); }
        sqlite::finalize(gone);
        exec_or_die(db, """
            DELETE FROM occurrences WHERE file NOT IN (SELECT file FROM temp.seen);
            DELETE FROM relationships WHERE file NOT IN (SELECT file FROM temp.seen);
            UPDATE symbols SET def_file = NULL, def_line = NULL, def_col = NULL,
                               body_start = NULL, body_end = NULL, body_start_col = NULL, body_end_col = NULL, in_repo = 0
            WHERE def_file NOT IN (SELECT file FROM temp.seen);
            DELETE FROM files WHERE file NOT IN (SELECT file FROM temp.seen);
            """);
    }
    sqlite::finalize(get_hash);
    sqlite::finalize(put_file);
    sqlite::finalize(drop_occ);
    sqlite::finalize(drop_rel);
    sqlite::finalize(reset_defs);
    sqlite::finalize(put_seen);

    // Symbols: found in this run's rows first, then in the database, and
    // otherwise added. A symbol keeps its id across refreshes.
    var ids = dictionary<const u8[:], i64> {};
    var syms: Sym[>..] = [];
    let find_sym = prepare_or_die(db, "SELECT id FROM symbols WHERE scip = ?1");
    let add_sym = prepare_or_die(db, """
        INSERT INTO symbols (scip, name, name_path, kind, signature, in_repo, language)
        VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6) RETURNING id
        """);

    fn intern(scip: const u8[:]) -> i64 {
        let got = ids.get(scip);
        if got { return got; }
        var db_id = -1;
        sqlite::bind_text(find_sym, 1, scip);
        if sqlite::step(find_sym, err) == 1 { db_id = sqlite::col_int(find_sym, 0); }
        sqlite::reset(find_sym);
        if db_id < 0 {
            var path: u8[>..] = [];
            let name, suffix, parent = describe(scip, path);
            let m = sigs.get(scip);
            let s = if m { m.sig } else { scip[0..0] };
            let sk = if m { m.kind } else { 0 };
            sqlite::bind_text(add_sym, 1, scip);
            sqlite::bind_text(add_sym, 2, name);
            sqlite::bind_text(add_sym, 3, path);
            sqlite::bind_text(add_sym, 4, kind_word(s, suffix, parent, sk));
            sqlite::bind_text(add_sym, 5, s);
            sqlite::bind_text(add_sym, 6, language_of(scip));
            if sqlite::step(add_sym, err) != 1 { abort(str("sqlite: ", err)); }
            db_id = sqlite::col_int(add_sym, 0);
            sqlite::reset(add_sym);
        }
        let k = syms.len;
        syms.push(Sym { db_id: db_id, def_file: scip[0..0], line: -1, col: -1,
                        body_start: -1, body_end: -1, body_start_col: -1, body_end_col: -1,
                        has_def: false, touched: false });
        ids.insert(scip, k);
        return k;
    }

    // extents.tsv: symbol, file, start_line, start_col, end_line, end_col, in
    // document order, so each file's extents are one run.
    var exts: Ext[>..] = [];
    var runs = dictionary<const u8[:], Span> {};
    each_split(text[b..c], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        guard changed.contains(f[1]);
        let k = intern(f[0]);
        let e = Ext { id: syms[k].db_id, sl: field_int(f[2]), sc: field_int(f[3]),
                      el: field_int(f[4]), ec: field_int(f[5]) };
        syms[k].body_start = e.sl;
        syms[k].body_end = e.el;
        syms[k].body_start_col = e.sc;
        syms[k].body_end_col = e.ec;
        syms[k].touched = true;
        runs.update(f[1], Span { lo: exts.len, hi: exts.len }) { it.hi = exts.len + 1; };
        exts.push(e);
    };

    // The smallest extent in the file that holds the position, or -1.
    fn enclosing(file: const u8[:], line: i64, col: i64) -> i64 {
        let r = runs.get(file);
        guard r else { return -1; }
        var best = -1;
        var best_size = 0;
        for k in r.lo..r.hi {
            let e = exts[k];
            let after_start = line > e.sl || (line == e.sl && col >= e.sc);
            let before_end = line < e.el || (line == e.el && col <= e.ec);
            if after_start && before_end {
                let size = (e.el - e.sl) * 100000 + (e.ec - e.sc);
                if best < 0 || size < best_size { best = e.id; best_size = size; }
            }
        }
        return best;
    }

    // occurrences.tsv: symbol, file, start_line, start_col, end_line, end_col, def|ref
    let ins_occ = prepare_or_die(db, "INSERT INTO occurrences VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)");
    var occ_count = 0;
    each_split(text[r..d], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        guard changed.contains(f[1]);
        let k = intern(f[0]);
        let sl = field_int(f[2]);
        let sc = field_int(f[3]);
        let is_def = f[6] == "def";
        if is_def && !syms[k].has_def {
            syms[k].has_def = true;
            syms[k].touched = true;
            syms[k].def_file = f[1];
            syms[k].line = sl;
            syms[k].col = sc;
        }
        sqlite::bind_int(ins_occ, 1, syms[k].db_id);
        sqlite::bind_text(ins_occ, 2, f[1]);
        sqlite::bind_int(ins_occ, 3, sl);
        sqlite::bind_int(ins_occ, 4, sc);
        sqlite::bind_int(ins_occ, 5, field_int(f[4]));
        sqlite::bind_int(ins_occ, 6, field_int(f[5]));
        sqlite::bind_int(ins_occ, 7, if is_def { 1 } else { 0 });
        sqlite::bind_int(ins_occ, 9, if f[6] == "name" { 1 } else { 0 });
        sqlite::bind_int(ins_occ, 10, if f[6] == "imp" { 1 } else { 0 });
        if !is_def {
            let enc = enclosing(f[1], sl, sc);
            if enc >= 0 { sqlite::bind_int(ins_occ, 8, enc); }
        }
        step_done(ins_occ);
        occ_count++;
    };
    sqlite::finalize(ins_occ);

    // relationships.tsv: symbol, file, related_symbol, flags (impl,ref,type,def)
    let ins_rel = prepare_or_die(db, "INSERT INTO relationships VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)");
    var rel_count = 0;
    each_split(text[c..r], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        guard f.len >= 4 && changed.contains(f[1]);
        let k = intern(f[0]);
        let j = intern(f[2]);
        let flags = split(f[3], ',');
        sqlite::bind_int(ins_rel, 1, syms[k].db_id);
        sqlite::bind_int(ins_rel, 2, syms[j].db_id);
        sqlite::bind_text(ins_rel, 3, f[1]);
        sqlite::bind_int(ins_rel, 4, if flags.contains("impl") { 1 } else { 0 });
        sqlite::bind_int(ins_rel, 5, if flags.contains("ref") { 1 } else { 0 });
        sqlite::bind_int(ins_rel, 6, if flags.contains("type") { 1 } else { 0 });
        sqlite::bind_int(ins_rel, 7, if flags.contains("def") { 1 } else { 0 });
        step_done(ins_rel);
        rel_count++;
    };
    sqlite::finalize(ins_rel);
    sqlite::finalize(find_sym);
    sqlite::finalize(add_sym);

    // The definitions found in rewritten files, and their current signatures.
    let upd_sym = prepare_or_die(db, """
        UPDATE symbols SET kind = ?2, signature = ?3, doc = ?12, def_file = ?4, def_line = ?5, def_col = ?6,
                           body_start = ?7, body_end = ?8, in_repo = ?9,
                           body_start_col = ?10, body_end_col = ?11
        WHERE id = ?1
        """);
    ids.each() { scip, k =>
        let s = syms[k];
        guard s.touched;
        var path: u8[>..] = [];
        let name, suffix, parent = describe(scip, path);
        let m = sigs.get(scip);
        let sg = if m { m.sig } else { scip[0..0] };
        let sk = if m { m.kind } else { 0 };
        sqlite::bind_int(upd_sym, 1, s.db_id);
        sqlite::bind_text(upd_sym, 2, kind_word(sg, suffix, parent, sk));
        sqlite::bind_text(upd_sym, 3, sg);
        if m && m.doc.len > 0 { sqlite::bind_text(upd_sym, 12, m.doc); }
        if s.has_def {
            sqlite::bind_text(upd_sym, 4, s.def_file);
            sqlite::bind_int(upd_sym, 5, s.line);
            sqlite::bind_int(upd_sym, 6, s.col);
        }
        if s.body_start >= 0 {
            sqlite::bind_int(upd_sym, 7, s.body_start);
            sqlite::bind_int(upd_sym, 8, s.body_end);
            sqlite::bind_int(upd_sym, 10, s.body_start_col);
            sqlite::bind_int(upd_sym, 11, s.body_end_col);
        }
        sqlite::bind_int(upd_sym, 9, if s.has_def { 1 } else { 0 });
        step_done(upd_sym);
    };
    sqlite::finalize(upd_sym);

    // A symbol nothing mentions any more goes.
    if refresh {
        exec_or_die(db, "DELETE FROM symbols WHERE in_repo = 0 AND id NOT IN (SELECT symbol_id FROM occurrences) AND id NOT IN (SELECT related_id FROM relationships);");
    }

    let ins_meta = prepare_or_die(db, "INSERT OR REPLACE INTO meta VALUES (?1, ?2)");
    fn meta(key: const u8[:], value: const u8[:]) {
        sqlite::bind_text(ins_meta, 1, key);
        sqlite::bind_text(ins_meta, 2, value);
        step_done(ins_meta);
    }
    let cnt = prepare_or_die(db, "SELECT (SELECT count(*) FROM symbols), (SELECT count(*) FROM occurrences)");
    var n_syms = 0;
    var n_occ = 0;
    if sqlite::step(cnt, err) == 1 { n_syms = sqlite::col_int(cnt, 0); n_occ = sqlite::col_int(cnt, 1); }
    sqlite::finalize(cnt);
    meta("schema_version", str(SCHEMA_VERSION));
    if !refresh || root.len > 0 { meta("root", root); }
    meta("source", dir);
    meta("scip_time", str(scip_time_of(dir)));
    if refresh { meta("refreshed_at", str(time())); } else { meta("built_at", str(time())); }
    meta("symbols", str(n_syms));
    meta("occurrences", str(n_occ));
    meta("files", str(hashes.count));
    sqlite::finalize(ins_meta);

    // scip-java names Kotlin symbols like Java ones; the file says which.
    exec_or_die(db, "UPDATE symbols SET language = 'kotlin' WHERE language = 'java' AND (def_file LIKE '%.kt' OR def_file LIKE '%.kts');");
    exec_or_die(db, "COMMIT;");
    if !refresh { exec_or_die(db, INDEXES); }
    sqlite::close(db);
    if !refresh {
        guard rename_file(tmp, db_path) else { abort(str("swan index: cannot rename ", tmp, " to ", db_path)); }
    }
    format(report, if refresh { "swan refresh: " } else { "swan index: " }, changed.count, " of ", hashes.count,
          " files rewritten", if removed > 0 { str(", ", removed, " removed") } else { str("") },
          "; ", occ_count, " occurrences and ", rel_count, " relationships written; map has ", n_syms, " symbols, ", n_occ,
          " occurrences -> ", db_path, " in ", ((clock() - t0) * 1000.0) as i64, " ms");
}
