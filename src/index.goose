// `swan index`: builds the code map from the flattened SCIP rows
// (tools/scip-flatten.ts) into SQLite. Goose does the map work: it interns
// symbols, parses their names and kinds, and finds the symbol each reference
// sits inside. SQLite stores the result and answers queries. The database is
// written beside its final path and renamed over it, so a reader never sees
// half an index.

import std;
import os;
import dictionary;

let SCHEMA_VERSION = 1;

struct Sym {
    scip: const u8[:],
    sig: const u8[:],
    def_file: const u8[:],
    line: i64, col: i64,             // the definition's name
    body_start: i64, body_end: i64,  // its whole span, -1 if SCIP gave none
    has_def: bool,
}

struct Ext { id: i64, sl: i64, sc: i64, el: i64, ec: i64 }

struct Span { lo: i64, hi: i64 }    // a file's run of extents

fn field_int(s: const u8[:]) -> i64 {
    let v, ok = parse_int(s);
    if !ok { abort(str("swan index: not a number: '", s, "'")); }
    return v;
}

fn index_main(dir: const u8[:], db_path: const u8[:], root: const u8[:]) {
    let t0 = clock();
    var text: u8[>..] = [];
    let a = text.len;
    guard read_file(str(dir, "/symbols.tsv"), text) else { abort(str("cannot read ", dir, "/symbols.tsv")); }
    let b = text.len;
    guard read_file(str(dir, "/extents.tsv"), text) else { abort(str("cannot read ", dir, "/extents.tsv")); }
    let c = text.len;
    guard read_file(str(dir, "/occurrences.tsv"), text) else { abort(str("cannot read ", dir, "/occurrences.tsv")); }
    let d = text.len;

    var ids = dictionary<const u8[:], i64> {};
    var syms: Sym[>..] = [];

    fn intern(scip: const u8[:]) -> i64 {
        let got = ids.get(scip);
        if got { return got; }
        let id = syms.len;
        syms.push(Sym { scip: scip, sig: scip[0..0], def_file: scip[0..0], line: -1, col: -1,
                        body_start: -1, body_end: -1, has_def: false });
        ids.insert(scip, id);
        return id;
    }

    // symbols.tsv: symbol, display_name, kind, enclosing_symbol, signature/doc line
    each_split(text[a..b], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        let id = intern(f[0]);
        if f.len > 4 { syms[id].sig = f[4]; }
    };

    // extents.tsv: symbol, file, start_line, start_col, end_line, end_col, in
    // document order, so each file's extents are one run.
    var exts: Ext[>..] = [];
    var runs = dictionary<const u8[:], Span> {};
    each_split(text[b..c], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        let id = intern(f[0]);
        let e = Ext { id: id, sl: field_int(f[2]), sc: field_int(f[3]), el: field_int(f[4]), ec: field_int(f[5]) };
        syms[id].body_start = e.sl;
        syms[id].body_end = e.el;
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

    // The database, beside its final name until it is complete.
    let tmp = str(db_path, ".tmp");
    if file_exists(tmp) { delete_file(tmp); }
    var err: u8[>..] = [];
    let db = swan_db_open(tmp, err);
    if db == 0 { abort(str("swan index: cannot open ", tmp, ": ", err)); }
    exec_or_die(db, """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE symbols (
            id INTEGER PRIMARY KEY,
            scip TEXT NOT NULL,
            name TEXT NOT NULL,
            name_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            signature TEXT NOT NULL,
            def_file TEXT,
            def_line INTEGER,
            def_col INTEGER,
            body_start INTEGER,
            body_end INTEGER,
            in_repo INTEGER NOT NULL
        );
        CREATE TABLE occurrences (
            symbol_id INTEGER NOT NULL,
            file TEXT NOT NULL,
            start_line INTEGER NOT NULL,
            start_col INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            end_col INTEGER NOT NULL,
            is_def INTEGER NOT NULL,
            enclosing_id INTEGER
        );
        BEGIN;
        """);

    // occurrences.tsv: symbol, file, start_line, start_col, end_line, end_col, def|ref
    let ins_occ = prepare_or_die(db, "INSERT INTO occurrences VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
    var occ_count = 0;
    each_split(text[c..d], '\n') {
        guard it.len > 0;
        let f = split(it, '\t');
        let id = intern(f[0]);
        let sl = field_int(f[2]);
        let sc = field_int(f[3]);
        let is_def = f[6] == "def";
        if is_def && !syms[id].has_def {
            syms[id].has_def = true;
            syms[id].def_file = f[1];
            syms[id].line = sl;
            syms[id].col = sc;
        }
        swan_bind_int(ins_occ, 1, id);
        swan_bind_text(ins_occ, 2, f[1]);
        swan_bind_int(ins_occ, 3, sl);
        swan_bind_int(ins_occ, 4, sc);
        swan_bind_int(ins_occ, 5, field_int(f[4]));
        swan_bind_int(ins_occ, 6, field_int(f[5]));
        swan_bind_int(ins_occ, 7, if is_def { 1 } else { 0 });
        if !is_def {
            let enc = enclosing(f[1], sl, sc);
            if enc >= 0 { swan_bind_int(ins_occ, 8, enc); }
        }
        step_done(ins_occ);
        occ_count++;
    };
    swan_finalize(ins_occ);

    let ins_sym = prepare_or_die(db,
        "INSERT INTO symbols VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)");
    for &s, id in syms {
        var path: u8[>..] = [];
        let name, suffix = describe(s.scip, path);
        swan_bind_int(ins_sym, 1, id);
        swan_bind_text(ins_sym, 2, s.scip);
        swan_bind_text(ins_sym, 3, name);
        swan_bind_text(ins_sym, 4, path);
        swan_bind_text(ins_sym, 5, kind_word(s.sig, suffix));
        swan_bind_text(ins_sym, 6, s.sig);
        if s.has_def {
            swan_bind_text(ins_sym, 7, s.def_file);
            swan_bind_int(ins_sym, 8, s.line);
            swan_bind_int(ins_sym, 9, s.col);
        }
        if s.body_start >= 0 {
            swan_bind_int(ins_sym, 10, s.body_start);
            swan_bind_int(ins_sym, 11, s.body_end);
        }
        swan_bind_int(ins_sym, 12, if s.has_def { 1 } else { 0 });
        step_done(ins_sym);
    }
    swan_finalize(ins_sym);

    let ins_meta = prepare_or_die(db, "INSERT INTO meta VALUES (?1, ?2)");
    fn meta(key: const u8[:], value: const u8[:]) {
        swan_bind_text(ins_meta, 1, key);
        swan_bind_text(ins_meta, 2, value);
        step_done(ins_meta);
    }
    meta("schema_version", str(SCHEMA_VERSION));
    meta("root", root);
    meta("source", dir);
    meta("built_at", str(time()));
    meta("symbols", str(syms.len));
    meta("occurrences", str(occ_count));
    swan_finalize(ins_meta);

    exec_or_die(db, """
        COMMIT;
        CREATE INDEX symbols_name ON symbols (name);
        CREATE INDEX symbols_name_path ON symbols (name_path);
        CREATE INDEX symbols_scip ON symbols (scip);
        CREATE INDEX symbols_def_file ON symbols (def_file);
        CREATE INDEX occurrences_symbol ON occurrences (symbol_id, is_def);
        CREATE INDEX occurrences_file ON occurrences (file, start_line);
        """);
    swan_db_close(db);
    guard rename_file(tmp, db_path) else { abort(str("swan index: cannot rename ", tmp, " to ", db_path)); }
    print("swan index: ", syms.len, " symbols, ", occ_count, " occurrences, ", exts.len,
          " extents -> ", db_path, " in ", ((clock() - t0) * 1000.0) as i64, " ms");
}
