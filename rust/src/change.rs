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
// the map find a file's line in a list. Moving a cosmetically edited file's
// rows to where its tokens sit now (shift_cosmetic) comes with the end of
// the map, which calls it.

use std::collections::HashMap;

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
