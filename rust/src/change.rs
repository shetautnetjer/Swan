// Telling a cosmetic edit from a real one, so that a refresh reruns an
// indexer only when the code changed.
//
// Swan used to stamp each file by its size and mtime, so any save reran its
// indexer: for TypeScript that is the whole program (47 s on rea, 6,787
// files), even when the edit was one comment. Now a file is stamped by what
// it holds (the map's `stamp`). For TypeScript, JavaScript and Python the
// stamp is of the code alone: a hash of the syntax tree (each node's kind
// and how many children it has, and each leaf's text) with comments and
// layout left out. An edit that leaves that hash as it was is cosmetic, and
// no indexer runs for it.
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
// Carried over from src/change.goose so far: the code stamp (cosmetic_lang,
// code_hash), and index_lines and line_of_path, by which the stamps and
// the map find a file's line in a list; and shift_cosmetic, which moves a
// cosmetically edited file's rows to where its tokens sit now, for the end
// of the map.

use std::collections::HashMap;

use crate::db::Db;
use crate::edit::{col_of, offset_of};
use crate::treesitter::{self, end, first, flags, next, start, sym};
use crate::util::{find, hash, hash_combine, hash_int, starts_with};

const CH_R: usize = treesitter::R; // ints per node in treesitter::parse's array
const CH_EXTRA: i64 = treesitter::F_EXTRA as i64; // comments and the like
const CH_ERROR: i64 = treesitter::F_ERROR as i64;

// The grammar cosmetic edits are told apart by, for this file; "" when its
// edits are compared byte for byte.
pub fn cosmetic_lang(path: &[u8]) -> &'static [u8] {
    let l = treesitter::language_of_path(path);
    if l == b"typescript" || l == b"tsx" || l == b"javascript" || l == b"python" {
        return l;
    }
    b""
}

// Whether an indexer reads this comment, so that it counts as code.
fn comment_counts(lang: &[u8], c: &[u8]) -> bool {
    if lang == b"python" {
        return starts_with(c, b"# type:") || starts_with(c, b"#type:") || starts_with(c, b"# pyright:") || starts_with(c, b"# mypy:");
    }
    if starts_with(c, b"/**") && c != b"/**/" {
        return true;
    }
    starts_with(c, b"///") || starts_with(c, b"//!") || starts_with(c, b"/*!") || find(c, b"@jsx") >= 0 || find(c, b"@ts-") >= 0 || find(c, b"@flow") >= 0
}

// The code's nodes in source order, with the comments that do not count
// left out: f(node, kids, leaf) for each, kids being how many of its
// children are kept. False when the tree holds a parse error.
fn each_code_node(lang: &[u8], text: &[u8], nodes: &[i32], mut f: impl FnMut(i64, i64, bool)) -> bool {
    if nodes.len() < CH_R {
        return false;
    }
    let dropped = |i: i64| -> bool {
        let fl = flags(nodes, i);
        if !((fl & CH_EXTRA) != 0 && (fl & CH_ERROR) == 0) {
            return false;
        }
        !comment_counts(lang, &text[start(nodes, i) as usize..end(nodes, i) as usize])
    };
    let mut stack: Vec<i64> = vec![0];
    while let Some(i) = stack.pop() {
        if i < 0 {
            continue;
        }
        stack.push(next(nodes, i));
        if dropped(i) {
            continue;
        }
        if (flags(nodes, i) & CH_ERROR) != 0 {
            return false;
        }
        let mut kids = 0;
        let mut c = first(nodes, i);
        while c >= 0 {
            if !dropped(c) {
                kids += 1;
            }
            c = next(nodes, c);
        }
        let leaf = first(nodes, i) < 0;
        f(i, kids, leaf);
        if !leaf {
            stack.push(first(nodes, i));
        }
    }
    true
}

// The hash of the code in `text` (see the top of this file). ok is false
// when it does not parse cleanly.
pub fn code_hash(lang: &[u8], text: &[u8]) -> (u64, bool) {
    let mut nodes: Vec<i32> = Vec::new();
    if !treesitter::parse(lang, text, &mut nodes) {
        return (0, false);
    }
    let mut h: u64 = hash(lang);
    let ok = each_code_node(lang, text, &nodes, |i, kids, leaf| {
        h = hash_combine(h, hash_int(sym(&nodes, i) * 65536 + kids));
        if leaf {
            h = hash_combine(h, hash(&text[start(&nodes, i) as usize..end(&nodes, i) as usize]));
        }
    });
    (h, ok)
}

// The byte spans of the code's leaves, each start then end.
fn code_tokens(lang: &[u8], text: &[u8], toks: &mut Vec<i64>) -> bool {
    let mut nodes: Vec<i32> = Vec::new();
    if !treesitter::parse(lang, text, &mut nodes) {
        return false;
    }
    each_code_node(lang, text, &nodes, |i, _kids, leaf| {
        if leaf {
            toks.push(start(&nodes, i));
            toks.push(end(&nodes, i));
        }
    })
}

fn line_starts(text: &[u8]) -> Vec<i64> {
    let mut starts: Vec<i64> = vec![0];
    for (i, &c) in text.iter().enumerate() {
        if c == b'\n' {
            starts.push(i as i64 + 1);
        }
    }
    starts
}

// The line holding byte `off`.
fn line_at(starts: &[i64], off: i64) -> i64 {
    let mut lo: i64 = 0;
    let mut hi: i64 = starts.len() as i64 - 1;
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if starts[mid as usize] <= off {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    lo
}

// Where byte `off` of the old text is in the new one, the two holding the
// same tokens (`old` and `new`, from code_tokens): at the same place in the
// same token. A position between tokens goes to the next token's start, or,
// for the end of a span (`at_end`), to the end of the token before. The end
// of the old text is the end of the new one, unless it is also the end of
// the last token: then a span ending there ends with that token.
fn moved_offset(old: &[i64], new: &[i64], off: i64, at_end: bool, old_len: i64, new_len: i64) -> i64 {
    let n = old.len() as i64 / 2;
    let o = |i: i64| old[i as usize];
    let w = |i: i64| new[i as usize];
    if off >= old_len {
        if at_end && n > 0 && o((n - 1) * 2 + 1) >= old_len {
            return w((n - 1) * 2 + 1);
        }
        return new_len;
    }
    if n <= 0 {
        return off.min(new_len);
    }
    let mut lo: i64 = 0;
    let mut hi: i64 = n - 1;
    let mut k: i64 = -1;
    while lo <= hi {
        let mid = (lo + hi) / 2;
        if o(mid * 2) <= off {
            k = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    if k < 0 {
        return w(0);
    }
    let s = o(k * 2);
    let e = o(k * 2 + 1);
    // The end of the token before, which this one starts right after.
    if at_end && off == s && k > 0 && o((k - 1) * 2 + 1) == off {
        return w((k - 1) * 2 + 1);
    }
    if off < e || (at_end && off == e) || off == s {
        return w(k * 2) + (off - s);
    }
    if at_end {
        return w(k * 2 + 1);
    }
    if k + 1 < n {
        w((k + 1) * 2)
    } else {
        new_len
    }
}

// Moves the map's rows for `rel` from where they sit in `old`, the text that
// was indexed, to the same code in `new`, which differs from it only in
// comments and layout. False, with nothing changed, when the two do not hold
// the same tokens.
pub fn shift_cosmetic(db: &Db, rel: &[u8], lang: &[u8], old: &[u8], new: &[u8]) -> bool {
    let mut a: Vec<i64> = Vec::new();
    let mut b: Vec<i64> = Vec::new();
    if !(code_tokens(lang, old, &mut a) && code_tokens(lang, new, &mut b) && a.len() == b.len()) {
        return false;
    }
    for k in 0..a.len() / 2 {
        if old[a[k * 2] as usize..a[k * 2 + 1] as usize] != new[b[k * 2] as usize..b[k * 2 + 1] as usize] {
            return false;
        }
    }
    let ostarts = line_starts(old);
    let nstarts = line_starts(new);
    let moved = |line: i64, col: i64, at_end: bool| -> (i64, i64) {
        let off = offset_of(old, &ostarts, line, col);
        let to = moved_offset(&a, &b, off, at_end, old.len() as i64, new.len() as i64);
        (line_at(&nstarts, to), col_of(new, to))
    };
    let mut occ: Vec<i64> = Vec::new(); // rowid, the four positions, is_def
    {
        let q = db.prepare_or_die(b"SELECT rowid, start_line, start_col, end_line, end_col, is_def FROM occurrences WHERE file = ?1");
        q.bind_text(1, rel);
        while q.step_checked() {
            for k in 0..6 {
                occ.push(q.col_int(k));
            }
        }
    }
    let mut defs: Vec<i64> = Vec::new(); // id, then def, body start and body end, -1 where unknown
    {
        let s = db.prepare_or_die(
            b"
        SELECT id, IFNULL(def_line, -1), IFNULL(def_col, -1), IFNULL(body_start, -1), IFNULL(body_start_col, -1),
               IFNULL(body_end, -1), IFNULL(body_end_col, -1)
        FROM symbols WHERE def_file = ?1
        ",
        );
        s.bind_text(1, rel);
        while s.step_checked() {
            for k in 0..7 {
                defs.push(s.col_int(k));
            }
        }
    }
    db.exec_or_die(b"BEGIN;");
    // Where each definition's name went, for its symbol's def_line and def_col.
    let mut def_at: HashMap<i64, i64> = HashMap::new();
    const W: i64 = 16777216;
    {
        let uo = db.prepare_or_die(b"UPDATE occurrences SET start_line = ?2, start_col = ?3, end_line = ?4, end_col = ?5 WHERE rowid = ?1");
        for r in 0..occ.len() / 6 {
            let o = r * 6;
            let (mut sl, mut sc, mut el, mut ec) = (0, 0, 0, 0);
            if occ[o + 1] == occ[o + 3] && occ[o + 2] == occ[o + 4] {
                // An empty span: the whole file's (a module's, at 0:0) stays where
                // the file starts; any other moves as a point.
                if occ[o + 1] != 0 || occ[o + 2] != 0 {
                    let (x, y) = moved(occ[o + 1], occ[o + 2], false);
                    sl = x;
                    sc = y;
                    el = x;
                    ec = y;
                }
            } else {
                let (x, y) = moved(occ[o + 1], occ[o + 2], false);
                let (u, v) = moved(occ[o + 3], occ[o + 4], true);
                sl = x;
                sc = y;
                el = u;
                ec = v;
            }
            if occ[o + 5] == 1 {
                def_at.insert(occ[o + 1] * W + occ[o + 2], sl * W + sc);
            }
            uo.bind_int(1, occ[o]);
            uo.bind_int(2, sl);
            uo.bind_int(3, sc);
            uo.bind_int(4, el);
            uo.bind_int(5, ec);
            uo.step_done();
        }
    }
    {
        let us = db.prepare_or_die(
            b"
        UPDATE symbols SET def_line = CASE WHEN ?2 < 0 THEN NULL ELSE ?2 END, def_col = CASE WHEN ?2 < 0 THEN NULL ELSE ?3 END,
                           body_start = CASE WHEN ?4 < 0 THEN NULL ELSE ?4 END, body_start_col = CASE WHEN ?4 < 0 THEN NULL ELSE ?5 END,
                           body_end = CASE WHEN ?6 < 0 THEN NULL ELSE ?6 END, body_end_col = CASE WHEN ?6 < 0 THEN NULL ELSE ?7 END
        WHERE id = ?1
        ",
        );
        for r in 0..defs.len() / 7 {
            let d = &defs[r * 7..r * 7 + 7];
            let (mut dl, mut dc, mut bsl, mut bsc, mut bel, mut bec) = (-1, -1, -1, -1, -1, -1);
            if d[1] >= 0 {
                if let Some(&t) = def_at.get(&(d[1] * W + d[2])) {
                    dl = t / W;
                    dc = t % W;
                } else {
                    let (x, y) = moved(d[1], d[2], false);
                    dl = x;
                    dc = y;
                }
            }
            if d[3] >= 0 {
                let (x, y) = moved(d[3], d[4], false);
                bsl = x;
                bsc = y;
            }
            if d[5] >= 0 {
                // The file's own symbol (defined at 0:0, a module) spans the whole
                // file, comments after its last code included.
                let whole = d[1] == 0 && d[2] == 0 && offset_of(old, &ostarts, d[5], d[6]) >= old.len() as i64;
                if whole {
                    bel = line_at(&nstarts, new.len() as i64);
                    bec = col_of(new, new.len() as i64);
                } else {
                    let (x, y) = moved(d[5], d[6], true);
                    bel = x;
                    bec = y;
                }
            }
            us.bind_int(1, d[0]);
            us.bind_int(2, dl);
            us.bind_int(3, dc);
            us.bind_int(4, bsl);
            us.bind_int(5, bsc);
            us.bind_int(6, bel);
            us.bind_int(7, bec);
            us.step_done();
        }
    }
    db.exec_or_die(b"COMMIT;");
    true
}

// Indexes "path\t..." lines by the hash of their path: at[hash] is where
// the line starts.
pub fn index_lines(text: &[u8], at: &mut HashMap<u64, usize>) {
    let mut i = 0;
    while i < text.len() {
        let nl = find(&text[i..], b"\n");
        let e = if nl >= 0 { i + nl as usize } else { text.len() };
        let t = find(&text[i..e], b"\t");
        if t > 0 {
            at.insert(hash(&text[i..i + t as usize]), i);
        }
        i = e + 1;
    }
}

// The line of `text` (indexed by index_lines) for `path`, or "".
pub fn line_of_path<'a>(text: &'a [u8], at: &HashMap<u64, usize>, path: &[u8]) -> &'a [u8] {
    let i = match at.get(&hash(path)) {
        Some(&i) => i,
        None => return &text[0..0],
    };
    let nl = find(&text[i..], b"\n");
    let line = if nl >= 0 { &text[i..i + nl as usize] } else { &text[i..] };
    if !(starts_with(line, path) && line.len() > path.len() && line[path.len()] == b'\t') {
        return &text[0..0];
    }
    line
}
