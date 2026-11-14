// Telling a cosmetic edit from a real one, so that a refresh reruns an
// indexer only when the code changed.
//
// Swan used to stamp each file by its size and mtime, so any save reran its
// indexer: for TypeScript that is the whole program (47 s on rea, 6,787
// files), even when the edit was one comment. Now a file is stamped by what
// it holds (src/pipeline.goose, `stamp`). For TypeScript, JavaScript and
// Python the stamp is of the code alone: a hash of the syntax tree (each
// node's kind and how many children it has, and each leaf's text) with
// comments and layout left out. An edit that leaves that hash as it was is
// cosmetic, and no indexer runs for it.
//
// Comments an indexer reads stay in the hash: doc comments (`/** */`, `///`,
// `//!`, `/*!`), which become a symbol's documentation, pragmas such as
// `@jsx` and `@ts-`, and Python's `# type:` comments. Python's docstrings
// are strings, so code. Indentation is in the tree's shape, so moving a
// Python line into or out of a block is a code change. A file that does not
// parse cleanly is stamped by its bytes, as are files in other languages:
// their indexers, or the flattener, read more of the text, so for them only
// a save that changes no byte is skipped.
//
// A cosmetic edit still moves code, and the map's rows came from the text
// that was indexed. Swan keeps a copy of each indexed text (<out>/texts/)
// and moves the rows of a cosmetically edited file to where the same tokens
// sit now (shift_cosmetic), as it does after its own edits (src/edit.goose).
// When it cannot, because it does not know which text the rows came from,
// the file is reindexed after all.

import std;
import os;
import sqlite;
import treesitter;

let CH_R = 8;          // ints per node in treesitter::parse's array
let CH_EXTRA = 2;      // treesitter's F_EXTRA: comments and the like
let CH_ERROR = 4;      // treesitter's F_ERROR

// The grammar cosmetic edits are told apart by, for this file; "" when its
// edits are compared byte for byte.
fn cosmetic_lang(path: const u8[:]) -> const u8[:] {
    let l = treesitter::language_of_path(path);
    if l == "typescript" || l == "tsx" || l == "javascript" || l == "python" { return l; }
    return l[0..0];
}

// Whether an indexer reads this comment, so that it counts as code.
fn comment_counts(lang: const u8[:], c: const u8[:]) -> bool {
    if lang == "python" {
        return starts_with(c, "# type:") || starts_with(c, "#type:") || starts_with(c, "# pyright:") ||
               starts_with(c, "# mypy:");
    }
    if starts_with(c, "/**") && c != "/**/" { return true; }
    return starts_with(c, "///") || starts_with(c, "//!") || starts_with(c, "/*!") ||
           find(c, "@jsx") >= 0 || find(c, "@ts-") >= 0 || find(c, "@flow") >= 0;
}

// The code's nodes in source order, with the comments that do not count
// left out: F(node, kids, leaf) for each, kids being how many of its
// children are kept. False when the tree holds a parse error.
fn each_code_node<F>(lang: const u8[:], text: const u8[:], nodes: const i32[:]) -> bool {
    guard nodes.len >= CH_R else { return false; }
    fn dropped(i: i64) -> bool {
        let fl = treesitter::flags(nodes, i);
        guard (fl & CH_EXTRA) != 0 && (fl & CH_ERROR) == 0 else { return false; }
        return !comment_counts(lang, text[treesitter::start(nodes, i)..treesitter::end(nodes, i)]);
    }
    var stack: i64[>..] = [];
    stack.push(0);
    while stack.len > 0 {
        let i = stack[stack.len - 1];
        stack.pop();
        if i < 0 { continue; }
        stack.push(treesitter::next(nodes, i));
        if dropped(i) { continue; }
        if (treesitter::flags(nodes, i) & CH_ERROR) != 0 { return false; }
        var kids = 0;
        var c = treesitter::first(nodes, i);
        while c >= 0 {
            if !dropped(c) { kids++; }
            c = treesitter::next(nodes, c);
        }
        let leaf = treesitter::first(nodes, i) < 0;
        F(i, kids, leaf);
        if !leaf { stack.push(treesitter::first(nodes, i)); }
    }
    return true;
}

// The hash of the code in `text` (see the top of this file). ok is false
// when it does not parse cleanly.
fn code_hash(lang: const u8[:], text: const u8[:]) -> u64, bool {
    var nodes: i32[>..] = [];
    guard treesitter::parse(lang, text, nodes) else { return 0, false; }
    var h: u64 = hash(lang);
    let ok = each_code_node(lang, text, nodes[..]) { i, kids, leaf =>
        h = hash_combine(h, hash(treesitter::sym(nodes[..], i) * 65536 + kids));
        if leaf { h = hash_combine(h, hash(text[treesitter::start(nodes[..], i)..treesitter::end(nodes[..], i)])); }
    };
    return h, ok;
}

// The byte spans of the code's leaves, each start then end.
fn code_tokens(lang: const u8[:], text: const u8[:], toks: i64[>..]&) -> bool {
    var nodes: i32[>..] = [];
    guard treesitter::parse(lang, text, nodes) else { return false; }
    let ok = each_code_node(lang, text, nodes[..]) { i, kids, leaf =>
        if leaf {
            toks.push(treesitter::start(nodes[..], i));
            toks.push(treesitter::end(nodes[..], i));
        }
    };
    return ok;
}

fn line_starts(text: const u8[:], starts: i64[>..]&) {
    starts.push(0);
    for c, i in text { if c == '\n' { starts.push(i + 1); } }
}

// The line holding byte `off`.
fn line_at(starts: const i64[:], off: i64) -> i64 {
    var lo = 0;
    var hi = starts.len - 1;
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if starts[mid] <= off { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
}

// Where byte `off` of the old text is in the new one, the two holding the
// same tokens (`old` and `new`, from code_tokens): at the same place in the
// same token. A position between tokens goes to the next token's start, or,
// for the end of a span (`at_end`), to the end of the token before. The end
// of the old text is the end of the new one, unless it is also the end of
// the last token: then a span ending there ends with that token.
fn moved_offset(old: const i64[:], new: const i64[:], off: i64, at_end: bool, old_len: i64, new_len: i64) -> i64 {
    let n = old.len / 2;
    if off >= old_len {
        if at_end && n > 0 && old[(n - 1) * 2 + 1] >= old_len { return new[(n - 1) * 2 + 1]; }
        return new_len;
    }
    guard n > 0 else { return min(off, new_len); }
    var lo = 0;
    var hi = n - 1;
    var k = -1;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        if old[mid * 2] <= off { k = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    guard k >= 0 else { return new[0]; }
    let s = old[k * 2];
    let e = old[k * 2 + 1];
    // The end of the token before, which this one starts right after.
    if at_end && off == s && k > 0 && old[(k - 1) * 2 + 1] == off { return new[(k - 1) * 2 + 1]; }
    if off < e || (at_end && off == e) || off == s { return new[k * 2] + (off - s); }
    if at_end { return new[k * 2 + 1]; }
    return if k + 1 < n { new[(k + 1) * 2] } else { new_len };
}

// Moves the map's rows for `rel` from where they sit in `old`, the text that
// was indexed, to the same code in `new`, which differs from it only in
// comments and layout. False, with nothing changed, when the two do not hold
// the same tokens.
fn shift_cosmetic(db: i64, rel: const u8[:], lang: const u8[:], old: const u8[:], new: const u8[:]) -> bool {
    var a: i64[>..] = [];
    var b: i64[>..] = [];
    guard code_tokens(lang, old, a) && code_tokens(lang, new, b) && a.len == b.len else { return false; }
    for k in a.len / 2 {
        if old[a[k * 2]..a[k * 2 + 1]] != new[b[k * 2]..b[k * 2 + 1]] { return false; }
    }
    var ostarts: i64[>..] = [];
    var nstarts: i64[>..] = [];
    line_starts(old, ostarts);
    line_starts(new, nstarts);
    fn moved(line: i64, col: i64, at_end: bool) -> i64, i64 {
        let off = offset_of(old, ostarts[..], line, col);
        let to = moved_offset(a[..], b[..], off, at_end, old.len, new.len);
        return line_at(nstarts[..], to), col_of(new, to);
    }
    var err: u8[>..] = [];
    var occ: i64[>..] = [];       // rowid, the four positions, is_def
    let q = prepare_or_die(db, "SELECT rowid, start_line, start_col, end_line, end_col, is_def FROM occurrences WHERE file = ?1");
    sqlite::bind_text(q, 1, rel);
    while step_checked(q, err) == 1 { for k in 6 { occ.push(sqlite::col_int(q, k as! i32)); } }
    sqlite::finalize(q);
    var defs: i64[>..] = [];      // id, then def, body start and body end, -1 where unknown
    let s = prepare_or_die(db, """
        SELECT id, IFNULL(def_line, -1), IFNULL(def_col, -1), IFNULL(body_start, -1), IFNULL(body_start_col, -1),
               IFNULL(body_end, -1), IFNULL(body_end_col, -1)
        FROM symbols WHERE def_file = ?1
        """);
    sqlite::bind_text(s, 1, rel);
    while step_checked(s, err) == 1 { for k in 7 { defs.push(sqlite::col_int(s, k as! i32)); } }
    sqlite::finalize(s);
    exec_or_die(db, "BEGIN;");
    let uo = prepare_or_die(db, "UPDATE occurrences SET start_line = ?2, start_col = ?3, end_line = ?4, end_col = ?5 WHERE rowid = ?1");
    // Where each definition's name went, for its symbol's def_line and def_col.
    var def_at = dictionary<i64, i64> {};
    let W: i64 = 16777216;
    for r in occ.len / 6 {
        let o = r * 6;
        var sl = 0; var sc = 0; var el = 0; var ec = 0;
        if occ[o + 1] == occ[o + 3] && occ[o + 2] == occ[o + 4] {
            // An empty span: the whole file's (a module's, at 0:0) stays where
            // the file starts; any other moves as a point.
            if occ[o + 1] != 0 || occ[o + 2] != 0 { let x, y = moved(occ[o + 1], occ[o + 2], false); sl = x; sc = y; el = x; ec = y; }
        } else {
            let x, y = moved(occ[o + 1], occ[o + 2], false);
            let u, v = moved(occ[o + 3], occ[o + 4], true);
            sl = x; sc = y; el = u; ec = v;
        }
        if occ[o + 5] == 1 { def_at.insert(occ[o + 1] * W + occ[o + 2], sl * W + sc); }
        sqlite::bind_int(uo, 1, occ[o]);
        sqlite::bind_int(uo, 2, sl);
        sqlite::bind_int(uo, 3, sc);
        sqlite::bind_int(uo, 4, el);
        sqlite::bind_int(uo, 5, ec);
        step_done(uo);
    }
    sqlite::finalize(uo);
    let us = prepare_or_die(db, """
        UPDATE symbols SET def_line = CASE WHEN ?2 < 0 THEN NULL ELSE ?2 END, def_col = CASE WHEN ?2 < 0 THEN NULL ELSE ?3 END,
                           body_start = CASE WHEN ?4 < 0 THEN NULL ELSE ?4 END, body_start_col = CASE WHEN ?4 < 0 THEN NULL ELSE ?5 END,
                           body_end = CASE WHEN ?6 < 0 THEN NULL ELSE ?6 END, body_end_col = CASE WHEN ?6 < 0 THEN NULL ELSE ?7 END
        WHERE id = ?1
        """);
    for r in defs.len / 7 {
        var dl = -1; var dc = -1; var bsl = -1; var bsc = -1; var bel = -1; var bec = -1;
        if defs[r * 7 + 1] >= 0 {
            let to = def_at.get(defs[r * 7 + 1] * W + defs[r * 7 + 2]);
            if to { let t: i64 = to; dl = t / W; dc = t % W; }
            else { let x, y = moved(defs[r * 7 + 1], defs[r * 7 + 2], false); dl = x; dc = y; }
        }
        if defs[r * 7 + 3] >= 0 { let x, y = moved(defs[r * 7 + 3], defs[r * 7 + 4], false); bsl = x; bsc = y; }
        if defs[r * 7 + 5] >= 0 {
            // The file's own symbol (defined at 0:0, a module) spans the whole
            // file, comments after its last code included.
            let whole = defs[r * 7 + 1] == 0 && defs[r * 7 + 2] == 0 &&
                        offset_of(old, ostarts[..], defs[r * 7 + 5], defs[r * 7 + 6]) >= old.len;
            if whole { bel = line_at(nstarts[..], new.len); bec = col_of(new, new.len); }
            else { let x, y = moved(defs[r * 7 + 5], defs[r * 7 + 6], true); bel = x; bec = y; }
        }
        sqlite::bind_int(us, 1, defs[r * 7]);
        sqlite::bind_int(us, 2, dl);
        sqlite::bind_int(us, 3, dc);
        sqlite::bind_int(us, 4, bsl);
        sqlite::bind_int(us, 5, bsc);
        sqlite::bind_int(us, 6, bel);
        sqlite::bind_int(us, 7, bec);
        step_done(us);
    }
    sqlite::finalize(us);
    exec_or_die(db, "COMMIT;");
    return true;
}

// Indexes "path\t..." lines by the hash of their path: at[hash] is where
// the line starts.
fn index_lines(text: const u8[:], at: dictionary<u64, i64>&) {
    var i = 0;
    while i < text.len {
        let nl = find(text[i..], "\n");
        let e = if nl >= 0 { i + nl } else { text.len };
        let t = find(text[i..e], "\t");
        if t > 0 { at.insert(hash(text[i..i + t]), i); }
        i = e + 1;
    }
}

// The line of `text` (indexed by index_lines) for `path`, or "".
fn line_of_path(text: const u8[:], at: dictionary<u64, i64>&, path: const u8[:]) -> const u8[:] {
    let found = at.get(hash(path));
    guard found else { return text[0..0]; }
    let i: i64 = found;
    let nl = find(text[i..], "\n");
    let line = if nl >= 0 { text[i..i + nl] } else { text[i..] };
    guard starts_with(line, path) && line.len > path.len && line[path.len] == '\t' else { return text[0..0]; }
    return line;
}
