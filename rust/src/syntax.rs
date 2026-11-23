// A syntax-level index for the languages no SCIP indexer covers here: Go,
// shell (bash, zsh, sh, and scripts named only by their #! line), Makefiles,
// Ruby and Lua. It writes a real SCIP file, so the flattener and `swan index`
// take it like any other, and a repo in these languages gets a map instead of
// "no language found".
//
// It reads source text only and runs nothing from the repo. Definitions come
// from line patterns, bodies from brace matching (Go, shell) or `end` at the
// same indentation (Ruby, Lua) or tab-indented recipe lines (Make).
// References are found by name: an identifier equal to a defined name, the
// nearest definition winning (same file, then same folder, then the only one
// in the repo). The flattener marks them "name" (found by name, not resolved
// by a compiler), and answers show them as by_name.
//
//   swan syntax-index <repo> <out.scip> [--skip go]
//
// Carried over from src/syntax.goose. Columns are UTF-8 bytes, the encoding
// the index declares. One thing is kept another way: the Goose program finds
// a name's definitions through a table keyed by a 64-bit hash of the language
// and the name, and this one through a table of names for each language.
// The answers are the same unless two different keys share that hash.

use std::collections::HashMap;

use crate::sys;
use crate::util::{ends_with, find, hash, push_int, rfind, starts_with, trim, TextMap, TextSet};
use crate::walk::Walk;

const SX_GO: i64 = 0;
const SX_SHELL: i64 = 1;
const SX_MAKE: i64 = 2;
const SX_RUBY: i64 = 3;
const SX_LUA: i64 = 4;

const SX_FUNCTION: i64 = 17;
const SX_METHOD: i64 = 26;
const SX_CLASS: i64 = 7;
const SX_MODULE: i64 = 29;
const SX_STRUCT: i64 = 49;
const SX_INTERFACE: i64 = 21;
const SX_TYPE: i64 = 54;
const SX_VARIABLE: i64 = 61;
const SX_CONSTANT: i64 = 8;

const SX_SKIP: [&[u8]; 15] = [
    b"node_modules",
    b".git",
    b"target",
    b".venv",
    b"venv",
    b"__pycache__",
    b".tox",
    b".mypy_cache",
    b".pytest_cache",
    b".swan",
    b"build",
    b".gradle",
    b"obj",
    b"vendor",
    b"dist",
];

fn sx_lang_name(l: i64) -> &'static [u8] {
    match l {
        SX_GO => b"go",
        SX_SHELL => b"shell",
        SX_MAKE => b"make",
        SX_RUBY => b"ruby",
        _ => b"lua",
    }
}

fn sx_w(c: u8) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_'
}
fn sx_alpha(c: u8) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_uppercase() || c == b'_'
}
fn sx_sp(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n' || c == b'\r' || c == 11 || c == 12
}

fn sx_skip_sp(s: &[u8], i: usize) -> usize {
    let mut k = i;
    while k < s.len() && sx_sp(s[k]) {
        k += 1;
    }
    k
}
fn sx_word_end(s: &[u8], i: usize) -> usize {
    let mut k = i;
    while k < s.len() && sx_w(s[k]) {
        k += 1;
    }
    k
}

// Whether some maximal run of word characters on the #! line equals w
// (the TypeScript's \bw\b on the first line).
fn sx_shebang_word(head: &[u8], w: &[u8]) -> bool {
    let mut i = 0;
    while i < head.len() && head[i] != b'\n' {
        if sx_w(head[i]) {
            let e = sx_word_end(head, i);
            if &head[i..e] == w {
                return true;
            }
            i = e;
        } else {
            i += 1;
        }
    }
    false
}

// The language of a file, or -1. skip_go is `--skip go`: Go is mapped by its
// language server in this run.
fn sx_lang_of(full: &[u8], name: &[u8], skip_go: bool) -> i64 {
    if ends_with(name, b".go") {
        return if skip_go { -1 } else { SX_GO };
    }
    for e in [&b".sh"[..], b".bash", b".zsh", b".ksh"] {
        if ends_with(name, e) {
            return SX_SHELL;
        }
    }
    if name == b"GNUmakefile" || name == b"makefile" || name == b"Makefile" || ends_with(name, b".mk") {
        return SX_MAKE;
    }
    if ends_with(name, b".rb") || name == b"Rakefile" {
        return SX_RUBY;
    }
    if ends_with(name, b".lua") {
        return SX_LUA;
    }
    if find(name, b".") >= 0 {
        return -1;
    }
    let mut text: Vec<u8> = Vec::new();
    if !sys::read_file(full, &mut text) {
        return -1;
    }
    let head = &text[..text.len().min(128)];
    if !starts_with(head, b"#!") {
        return -1;
    }
    for w in [&b"sh"[..], b"bash", b"zsh", b"ksh", b"dash"] {
        if sx_shebang_word(head, w) {
            return SX_SHELL;
        }
    }
    if sx_shebang_word(head, b"ruby") {
        return SX_RUBY;
    }
    -1
}

// Depth-first in sorted order (list_dir sorts bytewise), as the TypeScript
// walked: appends "<lang>\t<relative path>\n" for every file to index. An
// explicit stack: a folder's children go on in reverse, so the first sorted
// name comes off next and a subfolder is finished before its next sibling.
fn sx_walk(walk: &Walk, repo: &[u8], skip_go: bool, out: &mut Vec<u8>) {
    let mut stack: Vec<Vec<u8>> = Vec::new();
    let mut dir: Vec<u8> = repo.to_vec();
    let mut have_dir = true;
    loop {
        if have_dir {
            if let Some(names) = sys::list_dir(&dir) {
                for name in names.iter().rev() {
                    if !name.is_empty() {
                        stack.push([&dir[..], b"/", &name[..]].concat());
                    }
                }
            }
            have_dir = false;
        }
        let full = match stack.pop() {
            Some(f) => f,
            None => break,
        };
        let n = &full[(rfind(&full, b"/") + 1) as usize..];
        if sys::is_symlink(&full) {
            continue;
        }
        if sys::is_dir(&full) {
            // Hidden folders hold tooling and caches, as in each_file: Swan's own
            // .tools/lua-ls gave its map 29,744 Lua symbols that were not Swan's.
            if !n.is_empty() && n[0] != b'.' && !SX_SKIP.contains(&n) && !walk.skips(&full) {
                dir.clear();
                dir.extend_from_slice(&full);
                have_dir = true;
            }
        } else {
            let size = sys::file_size(&full);
            if size >= 0 && size <= 1000000 {
                let l = sx_lang_of(&full, n, skip_go);
                if l >= 0 {
                    push_int(out, l);
                    out.push(b'\t');
                    out.extend_from_slice(&full[repo.len() + 1..]);
                    out.push(b'\n');
                }
            }
        }
    }
}

// A SCIP descriptor name: as is when it is all [\w$+-], else in backticks.
pub(crate) fn sx_ident(s: &[u8], out: &mut Vec<u8>) {
    let mut plain = !s.is_empty();
    for &c in s {
        if !(sx_w(c) || c == b'$' || c == b'+' || c == b'-') {
            plain = false;
        }
    }
    if plain {
        out.extend_from_slice(s);
        return;
    }
    out.push(b'`');
    for &c in s {
        if c == b'`' {
            out.push(b'`');
        }
        out.push(c);
    }
    out.push(b'`');
}

pub(crate) fn sx_dirname(rel: &[u8]) -> &[u8] {
    let s = rfind(rel, b"/");
    if s < 0 {
        b"."
    } else {
        &rel[..s as usize]
    }
}
pub(crate) fn sx_basename(p: &[u8]) -> &[u8] {
    let mut e = p.len();
    while e > 1 && p[e - 1] == b'/' {
        e -= 1;
    }
    let s = rfind(&p[..e], b"/");
    &p[(s + 1) as usize..e]
}

// "a/b/" for folder a/b, "" for the repo's root.
pub(crate) fn sx_ns(dir: &[u8], out: &mut Vec<u8>) {
    if !(!dir.is_empty() && dir != b".") {
        return;
    }
    for seg in dir.split(|&c| c == b'/') {
        sx_ident(seg, out);
        out.push(b'/');
    }
}

// The line with comments and string contents blanked (same length up to a
// comment, which ends it), as the TypeScript's codeOnly.
fn sx_code(line: &[u8], lang: i64, out: &mut Vec<u8>) {
    out.clear();
    let mut q: u8 = 0;
    let mut i = 0;
    while i < line.len() {
        let c = line[i];
        if q != 0 {
            out.push(if c == q { c } else { b' ' });
            if c == b'\\' && q != b'`' {
                out.push(b' ');
                i += 1;
            }
            if c == q {
                q = 0;
            }
            i += 1;
            continue;
        }
        if lang == SX_GO && c == b'/' && i + 1 < line.len() && line[i + 1] == b'/' {
            break;
        }
        if lang == SX_LUA && c == b'-' && i + 1 < line.len() && line[i + 1] == b'-' {
            break;
        }
        if (lang == SX_SHELL || lang == SX_MAKE || lang == SX_RUBY) && c == b'#' && (i == 0 || sx_sp(line[i - 1])) {
            break;
        }
        if lang == SX_GO && (c == b'"' || c == b'`' || c == b'\'') {
            q = c;
            out.push(c);
            i += 1;
            continue;
        }
        out.push(c);
        i += 1;
    }
}

// Shell references skip a comment: from the first # at the start or after
// a space (the TypeScript's raw.replace(/(^|\s)#.*$/, "$1")).
fn sx_shell_code(line: &[u8], out: &mut Vec<u8>) {
    out.clear();
    for (i, &c) in line.iter().enumerate() {
        if c == b'#' && (i == 0 || sx_sp(line[i - 1])) {
            break;
        }
        out.push(c);
    }
}

// Protocol buffer encoding, as much of it as a SCIP index needs.
fn pb_varint(out: &mut Vec<u8>, n: i64) {
    let mut v = n as u64;
    while v > 127 {
        out.push(((v & 127) | 128) as u8);
        v >>= 7;
    }
    out.push(v as u8);
}
fn pb_key(out: &mut Vec<u8>, f: i64, wt: i64) {
    pb_varint(out, f * 8 + wt);
}
fn pb_bytes(out: &mut Vec<u8>, f: i64, v: &[u8]) {
    pb_key(out, f, 2);
    pb_varint(out, v.len() as i64);
    out.extend_from_slice(v);
}
fn pb_int(out: &mut Vec<u8>, f: i64, n: i64) {
    pb_key(out, f, 0);
    pb_varint(out, n);
}
// A packed repeated int32 field: [l, c, ec] on one line, [l, c, el, ec] across.
fn pb_range(out: &mut Vec<u8>, f: i64, l: usize, c: usize, el: usize, ec: usize) {
    let mut w: Vec<u8> = Vec::new();
    pb_varint(&mut w, l as i64);
    pb_varint(&mut w, c as i64);
    if el != l {
        pb_varint(&mut w, el as i64);
    }
    pb_varint(&mut w, ec as i64);
    pb_bytes(out, f, &w);
}

// At most n bytes of s, not cutting a UTF-8 character.
pub(crate) fn sx_cut(s: &[u8], n: usize) -> &[u8] {
    if s.len() <= n {
        return s;
    }
    let mut e = n;
    while e > 0 && (s[e] & 192) == 128 {
        e -= 1;
    }
    &s[..e]
}

// A line and a column as one number (a file is at most 1,000,000 bytes).
fn place(line: usize, col: usize) -> u64 {
    line as u64 * 16777216 + col as u64
}

// One file's text as lines.
struct Lines<'a> {
    text: &'a [u8],
    starts: Vec<usize>,
}

impl<'a> Lines<'a> {
    fn load(text: &'a [u8]) -> Self {
        let mut starts = vec![0];
        for (i, &c) in text.iter().enumerate() {
            if c == b'\n' {
                starts.push(i + 1);
            }
        }
        Lines { text, starts }
    }

    fn count(&self) -> usize {
        self.starts.len()
    }

    // Line l, without its newline or a \r before it.
    fn at(&self, l: usize) -> &'a [u8] {
        let s = self.starts[l];
        let mut e = if l + 1 < self.starts.len() { self.starts[l + 1] - 1 } else { self.text.len() };
        if e > s && self.text[e - 1] == b'\r' {
            e -= 1;
        }
        &self.text[s..e]
    }

    // Where a body that opens with a brace on (or just after) line `from`
    // closes. A parameter list may run over several lines before the brace
    // (gofmt puts one parameter per line): while its parenthesis is open the
    // search goes on, and braces inside it (`x struct{ a int }`) are not the
    // body. (Before, a function with two or more parameter lines got a
    // one-line body.)
    fn brace_end(&self, from: usize, lang: i64, code2: &mut Vec<u8>) -> (usize, usize) {
        let mut depth = 0;
        let mut paren = 0;
        let mut opened = false;
        let mut l = from;
        while l < self.count() && l < from + 20000 {
            sx_code(self.at(l), lang, code2);
            for (c, &ch) in code2.iter().enumerate() {
                if !opened && ch == b'(' {
                    paren += 1;
                } else if !opened && ch == b')' {
                    if paren > 0 {
                        paren -= 1;
                    }
                } else if ch == b'{' && (opened || paren == 0) {
                    depth += 1;
                    opened = true;
                } else if ch == b'}' && opened {
                    depth -= 1;
                    if depth == 0 {
                        return (l, c + 1);
                    }
                }
            }
            if !opened && paren == 0 && l > from + 1 {
                break;
            }
            l += 1;
        }
        (from, self.at(from).len())
    }

    // Where a body closed by `end` at the opening line's indentation ends.
    fn end_end(&self, from: usize) -> (usize, usize) {
        let indent = sx_skip_sp(self.at(from), 0);
        for l in from + 1..self.count() {
            let s = self.at(l);
            let k = sx_skip_sp(s, 0);
            if k == indent && starts_with(&s[k..], b"end") && (k + 3 == s.len() || !sx_w(s[k + 3])) {
                return (l, k + 3);
            }
        }
        (from, self.at(from).len())
    }
}

struct Def {
    name: Vec<u8>,
    sym: Vec<u8>,
    sig: Vec<u8>,
    kind: i64,
    line: usize,
    col: usize,
    end: usize,
    endcol: usize,
    file: usize,
    method: bool,
}

// Every definition, and for each language each name's definitions in the
// order they were found.
struct Defs {
    all: Vec<Def>,
    by_name: [TextMap<Vec<u8>, Vec<usize>>; 5],
}

impl Defs {
    #[allow(clippy::too_many_arguments)]
    fn add(&mut self, pkg: &[u8], desc: &[u8], lines: &Lines, fi: usize, lang: i64, name: &[u8], kind: i64, line: usize, col: usize, end: usize, endcol: usize, method: bool) {
        let d = self.all.len();
        self.all.push(Def {
            name: name.to_vec(),
            sym: [pkg, desc].concat(),
            sig: sx_cut(trim(lines.at(line)), 200).to_vec(),
            kind,
            line,
            col,
            end,
            endcol,
            file: fi,
            method,
        });
        self.by_name[lang as usize].entry(name.to_vec()).or_default().push(d);
    }
}

pub fn syntax_index_main(repo_arg: &[u8], out_path: &[u8], skip_go: bool) -> bool {
    let mut rend = repo_arg.len();
    while rend > 1 && repo_arg[rend - 1] == b'/' {
        rend -= 1;
    }
    let repo = &repo_arg[..rend];
    // The index goes into the map folder, which says what git ignores here.
    let mut walk = Walk::default();
    let cut = rfind(out_path, b"/");
    if cut > 0 {
        walk.load(repo, &out_path[..cut as usize]);
    }
    let mut listing: Vec<u8> = Vec::new();
    sx_walk(&walk, repo, skip_go, &mut listing);

    // Files: their paths, languages and text, in walk order.
    let mut paths: Vec<&[u8]> = Vec::new();
    let mut f_lang: Vec<i64> = Vec::new();
    let mut texts: Vec<Vec<u8>> = Vec::new();
    let mut f_dir: Vec<usize> = Vec::new(); // folder id, for "same folder"
    let mut dir_ids: HashMap<u64, usize> = HashMap::new();
    for line in listing.split(|&c| c == b'\n') {
        if line.len() <= 2 {
            continue;
        }
        let rel = &line[2..];
        let mut text: Vec<u8> = Vec::new();
        if !sys::read_file(&[repo, b"/", rel].concat(), &mut text) {
            continue;
        }
        paths.push(rel);
        f_lang.push((line[0] - b'0') as i64);
        texts.push(text);
        let n_dirs = dir_ids.len();
        f_dir.push(*dir_ids.entry(hash(sx_dirname(rel))).or_insert(n_dirs));
    }
    let nfiles = paths.len();

    let mut pkg: Vec<u8> = b"swan-syntax . ".to_vec();
    let mut rn: Vec<u8> = Vec::new();
    sx_ident(sx_basename(repo), &mut rn);
    for &c in &rn {
        pkg.push(if c == b' ' { b'_' } else { c });
    }
    pkg.extend_from_slice(b" 0 ");

    let mut defs = Defs { all: Vec::new(), by_name: Default::default() };
    let mut f_first: Vec<usize> = Vec::new(); // each file's definitions are one run

    let mut code: Vec<u8> = Vec::new();
    let mut code2: Vec<u8> = Vec::new();
    let mut desc: Vec<u8> = Vec::new();
    let mut ns: Vec<u8> = Vec::new();
    let mut file_ns: Vec<u8> = Vec::new();
    for fi in 0..nfiles {
        f_first.push(defs.all.len());
        let lines = Lines::load(&texts[fi]);
        let lang = f_lang[fi];
        let rel = paths[fi];
        ns.clear();
        sx_ns(sx_dirname(rel), &mut ns);
        file_ns.clear();
        file_ns.extend_from_slice(&ns);
        sx_ident(sx_basename(rel), &mut file_ns);
        file_ns.push(b'/');
        let mut go_type_block = false;
        for i in 0..lines.count() {
            sx_code(lines.at(i), lang, &mut code);
            let s = &code[..];
            if lang == SX_GO {
                if starts_with(s, b")") {
                    go_type_block = false;
                }
                let mut done = false;
                if starts_with(s, b"func") && s.len() > 4 && sx_sp(s[4]) {
                    // func (r *T) Name( or func (T) Name[
                    let mut k = sx_skip_sp(s, 4);
                    if k < s.len() && s[k] == b'(' {
                        k = sx_skip_sp(s, k + 1);
                        let a0 = k;
                        k = sx_word_end(s, k);
                        let a1 = k;
                        k = sx_skip_sp(s, k);
                        let mut star = false;
                        if k < s.len() && s[k] == b'*' {
                            star = true;
                            k = sx_skip_sp(s, k + 1);
                        }
                        let b0 = k;
                        k = sx_word_end(s, k);
                        let b1 = k;
                        let mut r0 = b0;
                        let mut r1 = b1;
                        if b1 == b0 && !star {
                            r0 = a0;
                            r1 = a1;
                        }
                        if r1 > r0 && k < s.len() && s[k] == b'[' {
                            let close = find(&s[k..], b"]");
                            k = if close >= 0 { k + close as usize + 1 } else { s.len() };
                        }
                        k = sx_skip_sp(s, k);
                        if r1 > r0 && k < s.len() && s[k] == b')' {
                            k = sx_skip_sp(s, k + 1);
                            let n0 = k;
                            let n1 = sx_word_end(s, k);
                            let after = sx_skip_sp(s, n1);
                            if n1 > n0 && after < s.len() && (s[after] == b'(' || s[after] == b'[') {
                                desc.clear();
                                desc.extend_from_slice(&ns);
                                sx_ident(&s[r0..r1], &mut desc);
                                desc.push(b'#');
                                sx_ident(&s[n0..n1], &mut desc);
                                desc.extend_from_slice(b"().");
                                let (e, ec) = lines.brace_end(i, SX_GO, &mut code2);
                                defs.add(&pkg, &desc, &lines, fi, lang, &s[n0..n1], SX_METHOD, i, n0, e, ec, true);
                                done = true;
                            }
                        }
                    } else {
                        let n1 = sx_word_end(s, k);
                        let after = sx_skip_sp(s, n1);
                        if n1 > k && after < s.len() && (s[after] == b'(' || s[after] == b'[') {
                            desc.clear();
                            desc.extend_from_slice(&ns);
                            sx_ident(&s[k..n1], &mut desc);
                            desc.extend_from_slice(b"().");
                            let (e, ec) = lines.brace_end(i, SX_GO, &mut code2);
                            defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], SX_FUNCTION, i, k, e, ec, false);
                            done = true;
                        }
                    }
                }
                if !done && starts_with(s, b"type") && s.len() > 4 && sx_sp(s[4]) && s[s.len() - 1] == b'(' && sx_skip_sp(s, 4) == s.len() - 1 {
                    go_type_block = true;
                    done = true;
                }
                if !done && (starts_with(s, b"type") || go_type_block) {
                    let mut at: Option<usize> = None;
                    if starts_with(s, b"type") && s.len() > 4 && sx_sp(s[4]) {
                        at = Some(sx_skip_sp(s, 4));
                    } else if starts_with(s, b"\t") {
                        at = Some(1);
                    }
                    if let Some(k) = at {
                        let n1 = sx_word_end(s, k);
                        // Past the name and its type parameters; None when their bracket is not closed.
                        let mut past: Option<usize> = Some(n1);
                        if n1 > k && n1 < s.len() && s[n1] == b'[' {
                            let close = find(&s[n1..], b"]");
                            past = if close >= 0 { Some(n1 + close as usize + 1) } else { None };
                        }
                        if let Some(j) = past {
                            if n1 > k && j < s.len() && sx_sp(s[j]) {
                                let w = sx_skip_sp(s, j);
                                let is_struct = starts_with(&s[w..], b"struct");
                                let is_iface = starts_with(&s[w..], b"interface");
                                let kind = if is_struct {
                                    SX_STRUCT
                                } else if is_iface {
                                    SX_INTERFACE
                                } else {
                                    SX_TYPE
                                };
                                desc.clear();
                                desc.extend_from_slice(&ns);
                                sx_ident(&s[k..n1], &mut desc);
                                desc.push(b'#');
                                if is_struct || is_iface {
                                    let (e, ec) = lines.brace_end(i, SX_GO, &mut code2);
                                    defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], kind, i, k, e, ec, false);
                                } else {
                                    defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], kind, i, k, i, lines.at(i).len(), false);
                                }
                                done = true;
                            }
                        }
                    }
                }
                if !done {
                    let mut at: Option<usize> = None;
                    let mut kind = SX_VARIABLE;
                    if starts_with(s, b"var") && s.len() > 3 && sx_sp(s[3]) {
                        at = Some(sx_skip_sp(s, 3));
                    } else if starts_with(s, b"const") && s.len() > 5 && sx_sp(s[5]) {
                        at = Some(sx_skip_sp(s, 5));
                        kind = SX_CONSTANT;
                    }
                    if let Some(k) = at {
                        let n1 = sx_word_end(s, k);
                        if n1 > k {
                            desc.clear();
                            desc.extend_from_slice(&ns);
                            sx_ident(&s[k..n1], &mut desc);
                            desc.push(b'.');
                            defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], kind, i, k, i, lines.at(i).len(), false);
                        }
                    }
                }
            } else if lang == SX_SHELL {
                let k = sx_skip_sp(s, 0);
                let mut name: Option<(usize, usize)> = None;
                if starts_with(&s[k..], b"function") && k + 8 < s.len() && sx_sp(s[k + 8]) {
                    let a = sx_skip_sp(s, k + 8);
                    if a < s.len() && sx_alpha(s[a]) {
                        let mut e = a + 1;
                        while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'.' || s[e] == b'-') {
                            e += 1;
                        }
                        name = Some((a, e));
                    }
                } else if k < s.len() && sx_alpha(s[k]) {
                    let mut e = k + 1;
                    while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'.' || s[e] == b'-') {
                        e += 1;
                    }
                    let mut j = sx_skip_sp(s, e);
                    if j < s.len() && s[j] == b'(' {
                        j = sx_skip_sp(s, j + 1);
                        if j < s.len() && s[j] == b')' {
                            name = Some((k, e));
                        }
                    }
                }
                if let Some((n0, n1)) = name {
                    desc.clear();
                    desc.extend_from_slice(&file_ns);
                    sx_ident(&s[n0..n1], &mut desc);
                    desc.extend_from_slice(b"().");
                    let (e, ec) = lines.brace_end(i, SX_SHELL, &mut code2);
                    defs.add(&pkg, &desc, &lines, fi, lang, &s[n0..n1], SX_FUNCTION, i, n0, e, ec, false);
                }
            } else if lang == SX_MAKE {
                if !s.is_empty() && sx_w(s[0]) {
                    let mut e = 1;
                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b'-' || s[e] == b'/') {
                        e += 1;
                    }
                    let j = sx_skip_sp(s, e);
                    if j < s.len() && s[j] == b':' && (j + 1 == s.len() || (s[j + 1] != b'=' && s[j + 1] != b':')) {
                        let mut last = i;
                        while last + 1 < lines.count() && starts_with(lines.at(last + 1), b"\t") {
                            last += 1;
                        }
                        desc.clear();
                        desc.extend_from_slice(&file_ns);
                        sx_ident(&s[..e], &mut desc);
                        desc.extend_from_slice(b"().");
                        defs.add(&pkg, &desc, &lines, fi, lang, &s[..e], SX_FUNCTION, i, 0, last, lines.at(last).len(), false);
                    }
                }
            } else if lang == SX_RUBY {
                let k = sx_skip_sp(s, 0);
                let mut kw = 0;
                if starts_with(&s[k..], b"class") {
                    kw = 5;
                } else if starts_with(&s[k..], b"module") {
                    kw = 6;
                }
                let mut done = false;
                if kw > 0 && k + kw < s.len() && sx_sp(s[k + kw]) {
                    let a = sx_skip_sp(s, k + kw);
                    if a < s.len() && s[a] >= b'A' && s[a] <= b'Z' {
                        let mut e = sx_word_end(s, a);
                        let mut last0 = a;
                        while e + 2 < s.len() && s[e] == b':' && s[e + 1] == b':' && sx_w(s[e + 2]) {
                            last0 = e + 2;
                            e = sx_word_end(s, e + 2);
                        }
                        desc.clear();
                        desc.extend_from_slice(&file_ns);
                        sx_ident(&s[a..e], &mut desc);
                        desc.push(b'#');
                        let (le, lc) = lines.end_end(i);
                        defs.add(&pkg, &desc, &lines, fi, lang, &s[last0..e], if kw == 5 { SX_CLASS } else { SX_MODULE }, i, a, le, lc, false);
                        done = true;
                    }
                }
                if !done && starts_with(&s[k..], b"def") && k + 3 < s.len() && sx_sp(s[k + 3]) {
                    let mut a = sx_skip_sp(s, k + 3);
                    if starts_with(&s[a..], b"self.") {
                        a += 5;
                    }
                    if a < s.len() && sx_alpha(s[a]) {
                        let mut e = sx_word_end(s, a);
                        if e < s.len() && (s[e] == b'?' || s[e] == b'!' || s[e] == b'=') {
                            e += 1;
                        }
                        desc.clear();
                        desc.extend_from_slice(&file_ns);
                        sx_ident(&s[a..e], &mut desc);
                        desc.extend_from_slice(b"().");
                        let (le, lc) = lines.end_end(i);
                        defs.add(&pkg, &desc, &lines, fi, lang, &s[a..e], SX_METHOD, i, a, le, lc, true);
                    }
                }
            } else {
                let mut k = sx_skip_sp(s, 0);
                if starts_with(&s[k..], b"local") && k + 5 < s.len() && sx_sp(s[k + 5]) {
                    k = sx_skip_sp(s, k + 5);
                }
                if starts_with(&s[k..], b"function") && k + 8 < s.len() && sx_sp(s[k + 8]) {
                    let a = sx_skip_sp(s, k + 8);
                    let mut e = a;
                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b':') {
                        e += 1;
                    }
                    let j = sx_skip_sp(s, e);
                    if e > a && j < s.len() && s[j] == b'(' {
                        let mut n0 = a;
                        for x in a..e {
                            if s[x] == b'.' || s[x] == b':' {
                                n0 = x + 1;
                            }
                        }
                        desc.clear();
                        desc.extend_from_slice(&file_ns);
                        sx_ident(&s[a..e], &mut desc);
                        desc.extend_from_slice(b"().");
                        let (le, lc) = lines.end_end(i);
                        defs.add(&pkg, &desc, &lines, fi, lang, &s[n0..e], SX_FUNCTION, i, n0, le, lc, n0 > a);
                    }
                }
            }
        }
    }
    f_first.push(defs.all.len());

    // The SCIP index.
    let mut top: Vec<u8> = Vec::new();
    let mut meta: Vec<u8> = Vec::new();
    pb_int(&mut meta, 1, 0);
    let mut tool: Vec<u8> = Vec::new();
    pb_bytes(&mut tool, 1, b"swan-syntax");
    pb_bytes(&mut tool, 2, b"1");
    pb_bytes(&mut meta, 2, &tool);
    pb_bytes(&mut meta, 3, &[b"file://", repo].concat());
    pb_int(&mut meta, 4, 1);
    pb_bytes(&mut top, 1, &meta);

    let mut n_occ = 0;
    let mut hits: Vec<Option<usize>> = Vec::new();
    let mut occ: Vec<u8> = Vec::new();
    let mut info: Vec<u8> = Vec::new();
    let mut docm: Vec<u8> = Vec::new();
    for fi in 0..nfiles {
        let lines = Lines::load(&texts[fi]);
        let lang = f_lang[fi];
        let rel = paths[fi];
        let lname = sx_lang_name(lang);
        let mut doc: Vec<u8> = Vec::new();
        pb_bytes(&mut doc, 1, rel);
        pb_bytes(&mut doc, 4, if lang == SX_MAKE { b"Makefile" } else { lname });
        // The file itself, as scip-typescript names a module.
        let mut msym: Vec<u8> = pkg.clone();
        sx_ns(sx_dirname(rel), &mut msym);
        sx_ident(sx_basename(rel), &mut msym);
        msym.push(b'/');
        let last = lines.count() - 1;
        occ.clear();
        pb_range(&mut occ, 1, 0, 0, 0, 0);
        pb_bytes(&mut occ, 2, &msym);
        pb_int(&mut occ, 3, 1);
        pb_range(&mut occ, 7, 0, 0, last, lines.at(last).len());
        pb_bytes(&mut doc, 2, &occ);
        n_occ += 1;
        let mut def_at: TextSet<u64> = TextSet::default(); // where a definition's name is: its line and column
        for d in &defs.all[f_first[fi]..f_first[fi + 1]] {
            occ.clear();
            pb_range(&mut occ, 1, d.line, d.col, d.line, d.col + d.name.len());
            pb_bytes(&mut occ, 2, &d.sym);
            pb_int(&mut occ, 3, 1);
            pb_range(&mut occ, 7, d.line, 0, d.end, d.endcol);
            pb_bytes(&mut doc, 2, &occ);
            n_occ += 1;
            def_at.insert(place(d.line, d.col));
        }
        // References by name.
        let my_dir = f_dir[fi];
        for i in 0..lines.count() {
            if lang == SX_SHELL {
                sx_shell_code(lines.at(i), &mut code);
            } else {
                sx_code(lines.at(i), lang, &mut code);
            }
            let s = &code[..];
            let mut c = 0;
            while c < s.len() {
                let ch = s[c];
                let start_ok = if lang == SX_MAKE { sx_w(ch) } else { sx_alpha(ch) };
                if !start_ok {
                    c += 1;
                    continue;
                }
                let mut e = c + 1;
                if lang == SX_SHELL {
                    while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'-') {
                        e += 1;
                    }
                } else if lang == SX_MAKE {
                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b'-' || s[e] == b'/') {
                        e += 1;
                    }
                } else {
                    e = sx_word_end(s, e);
                    if lang == SX_RUBY && e < s.len() && (s[e] == b'?' || s[e] == b'!') {
                        e += 1;
                    }
                }
                let tok = &s[c..e];
                if !def_at.contains(&place(i, c)) {
                    // resolve: same file, then same folder, then the repo;
                    // the first tier with any decides, and only if it has at most 3.
                    if let Some(pool) = defs.by_name[lang as usize].get(tok) {
                        let any_method = pool.iter().any(|&d| defs.all[d].method);
                        let after_dot = c > 0 && s[c - 1] == b'.';
                        let only_methods = lang == SX_GO && after_dot && any_method;
                        hits.clear();
                        for tier in 0..3 {
                            if hits.is_empty() {
                                let in_tier = |d2: usize| {
                                    let f2 = defs.all[d2].file;
                                    let near = if tier == 0 {
                                        f2 == fi
                                    } else if tier == 1 {
                                        f_dir[f2] == my_dir
                                    } else {
                                        true
                                    };
                                    near && (!only_methods || defs.all[d2].method)
                                };
                                let n = pool.iter().filter(|&&d2| in_tier(d2)).count();
                                if n > 3 {
                                    hits.push(None); // decided: too many
                                } else if n > 0 {
                                    for &d2 in pool {
                                        if in_tier(d2) {
                                            hits.push(Some(d2));
                                        }
                                    }
                                }
                            }
                        }
                        for d2 in hits.iter().flatten() {
                            occ.clear();
                            pb_range(&mut occ, 1, i, c, i, e);
                            pb_bytes(&mut occ, 2, &defs.all[*d2].sym);
                            pb_bytes(&mut doc, 2, &occ);
                            n_occ += 1;
                        }
                    }
                }
                c = e;
            }
        }
        // Symbol information: the module, then each definition.
        info.clear();
        pb_bytes(&mut info, 1, &msym);
        docm.clear();
        docm.extend_from_slice(b"```");
        docm.extend_from_slice(lname);
        docm.push(b'\n');
        docm.extend_from_slice(sx_basename(rel));
        docm.extend_from_slice(b"\n```");
        pb_bytes(&mut info, 3, &docm);
        pb_int(&mut info, 5, SX_MODULE);
        pb_bytes(&mut info, 6, sx_basename(rel));
        pb_bytes(&mut doc, 3, &info);
        for d in &defs.all[f_first[fi]..f_first[fi + 1]] {
            info.clear();
            pb_bytes(&mut info, 1, &d.sym);
            docm.clear();
            docm.extend_from_slice(b"```");
            docm.extend_from_slice(lname);
            docm.push(b'\n');
            docm.extend_from_slice(&d.sig);
            docm.extend_from_slice(b"\n```");
            pb_bytes(&mut info, 3, &docm);
            pb_int(&mut info, 5, d.kind);
            pb_bytes(&mut info, 6, &d.name);
            pb_bytes(&mut doc, 3, &info);
        }
        pb_bytes(&mut top, 2, &doc);
    }
    if !sys::write_file(out_path, &top) {
        sys::write_stderr(&[b"syntax-index: cannot write ", out_path, b"\n"].concat());
        return false;
    }
    sys::write_stderr(format!("syntax-index: {} files, {} definitions, {} occurrences\n", nfiles, defs.all.len(), n_occ).as_bytes());
    true
}
