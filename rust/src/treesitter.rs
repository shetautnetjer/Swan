// Tree-sitter for Swan: the grammars and the runtime are C (goose-
// treesitter's ts_shim.c, built by build.rs from the same sources the Goose
// program builds), reached through an opaque handle and plain slices.
// Carried over from goose-treesitter's treesitter.goose; the structural
// search (compile, search, bindings) follows with `query pattern`.
//
// Kept free of the rest of the crate, so the port's tree dumper
// (src/bin/port-trees.rs) can include it alone.

#[repr(C)]
struct TsSlice {
    data: *const u8,
    len: i64,
}

#[repr(C)]
struct TsInts {
    data: *mut i32,
    len: i64,
}

extern "C" {
    fn swan_ts_parse(lang: TsSlice, src: TsSlice) -> i64;
    fn swan_ts_free(h: i64);
    fn swan_ts_count(h: i64) -> i64;
    fn swan_ts_fill(h: i64, out: TsInts) -> i64;
}

fn slice(s: &[u8]) -> TsSlice {
    TsSlice { data: s.as_ptr(), len: s.len() as i64 }
}

// Each node is R ints: symbol, flags, start and end byte, start row and
// column (0-based), first child, next sibling (-1 for none).
pub const R: usize = 8;
#[allow(dead_code)]
pub const F_NAMED: i32 = 1;
#[allow(dead_code)]
pub const F_EXTRA: i32 = 2;
#[allow(dead_code)]
pub const F_ERROR: i32 = 4;

// Parses src into `nodes` (pre-order, the root first). False when the
// language has no grammar here.
pub fn parse(lang: &[u8], src: &[u8], nodes: &mut Vec<i32>) -> bool {
    let h = unsafe { swan_ts_parse(slice(lang), slice(src)) };
    if h == 0 {
        return false;
    }
    let n = unsafe { swan_ts_count(h) } as usize;
    nodes.clear();
    nodes.resize(n * R, 0);
    unsafe {
        swan_ts_fill(h, TsInts { data: nodes.as_mut_ptr(), len: nodes.len() as i64 });
        swan_ts_free(h);
    }
    true
}

// The grammar for a file, by its name; "" when there is none.
pub fn language_of_path(p: &[u8]) -> &'static [u8] {
    let e = |x: &[u8]| p.ends_with(x);
    if e(b".ts") || e(b".mts") || e(b".cts") {
        return b"typescript";
    }
    if e(b".tsx") {
        return b"tsx";
    }
    if e(b".js") || e(b".jsx") || e(b".mjs") || e(b".cjs") {
        return b"javascript";
    }
    if e(b".py") || e(b".pyi") {
        return b"python";
    }
    if e(b".rs") {
        return b"rust";
    }
    if e(b".java") {
        return b"java";
    }
    if e(b".c") || e(b".h") {
        return b"c";
    }
    if e(b".cc") || e(b".cpp") || e(b".cxx") || e(b".hpp") || e(b".hh") || e(b".hxx") {
        return b"cpp";
    }
    if e(b".cu") || e(b".cuh") {
        return b"cuda";
    }
    if e(b".kt") || e(b".kts") {
        return b"kotlin";
    }
    if e(b".lua") {
        return b"lua";
    }
    if e(b".glsl") || e(b".vert") || e(b".frag") || e(b".comp") || e(b".geom") || e(b".tesc") || e(b".tese") {
        return b"glsl";
    }
    if e(b".hlsl") || e(b".hlsli") || e(b".fx") {
        return b"hlsl";
    }
    if e(b".wgsl") {
        return b"wgsl";
    }
    if e(b".gd") {
        return b"gdscript";
    }
    if e(b".cs") {
        return b"csharp";
    }
    if e(b".php") {
        return b"php";
    }
    b""
}

// ---- the structural matcher (goose-treesitter's treesitter.goose) ----------
//
// A pattern is code in the target's language with metavariables, `$X` for
// any one node and `$$$X` for any run of siblings (none included). `$_` and
// names starting with `_` match without capturing; a name used twice must
// match the same text both times.

fn find(hay: &[u8], needle: &[u8]) -> i64 {
    if needle.is_empty() {
        return 0;
    }
    hay.windows(needle.len()).position(|w| w == needle).map(|p| p as i64).unwrap_or(-1)
}

fn trim(s: &[u8]) -> &[u8] {
    // Goose's is_space: these four only.
    let sp = |c: u8| c == b' ' || c == b'\t' || c == b'\n' || c == b'\r';
    let mut a = 0;
    let mut b = s.len();
    while a < b && sp(s[a]) {
        a += 1;
    }
    while b > a && sp(s[b - 1]) {
        b -= 1;
    }
    &s[a..b]
}

fn is_word(s: &[u8]) -> bool {
    s.iter().all(|&c| c.is_ascii_lowercase() || c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_')
}

fn is_meta_char(c: u8) -> bool {
    c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_'
}

// Not __-prefixed: WGSL reserves identifiers that start with two underscores.
const MV: &[u8] = b"zswan_mv_"; // $X becomes zswan_mv_X
const MVM: &[u8] = b"zswan_mvm_"; // $$$X becomes zswan_mvm_X

fn sym(n: &[i32], i: i64) -> i64 {
    n[i as usize * R] as i64
}
fn flags(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 1] as i64
}
fn start(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 2] as i64
}
fn end(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 3] as i64
}
fn row(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 4] as i64
}
fn col(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 5] as i64
}
fn first(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 6] as i64
}
fn next(n: &[i32], i: i64) -> i64 {
    n[i as usize * R + 7] as i64
}

// Skips comments and other extras (tree-sitter counts error nodes as extras
// too, but a pattern's metavariable can be one).
fn solid(n: &[i32], i: i64) -> i64 {
    let mut k = i;
    while k >= 0 && (flags(n, k) & (F_EXTRA | F_ERROR) as i64) == F_EXTRA as i64 {
        k = next(n, k);
    }
    k
}

// Where a Lua long bracket that opens at `at` ([[, [=[, [==[ ...) ends, just
// past its closing bracket; 0 when there is none at `at`.
fn lua_long_bracket(p: &[u8], at: usize) -> usize {
    if !(at < p.len() && p[at] == b'[') {
        return 0;
    }
    let mut lv = 0;
    let mut j = at + 1;
    while j < p.len() && p[j] == b'=' {
        lv += 1;
        j += 1;
    }
    if !(j < p.len() && p[j] == b'[') {
        return 0;
    }
    j += 1;
    while j < p.len() {
        if p[j] == b']' {
            let mut k = 0;
            while j + 1 + k < p.len() && p[j + 1 + k] == b'=' {
                k += 1;
            }
            if k == lv && j + 1 + k < p.len() && p[j + 1 + k] == b']' {
                return j + 2 + k;
            }
        }
        j += 1;
    }
    p.len()
}

// $X and $$$X as identifiers every grammar accepts. A `$` inside a string
// literal is text (`printf("$HOME")` matches only that string), so it is
// kept. The pattern's own language says what a string and a comment are:
// "..." everywhere, with Python/Kotlin/Java triple quotes and Rust raw
// strings; '...' and `...` strings in Python and JS/TS, where in
// the C family and Rust '"' is a character (and 'a a Rust lifetime);
// // and /* */ comments except in Python, which has # (and // for division);
// '...' strings in Lua, GDScript and PHP too; # comments in GDScript and PHP;
// Lua's -- comments and [[ ]] long strings. In PHP, $ followed by a
// lowercase letter is a PHP variable and left alone; metavariables are
// upper case ($X), so PHP's own $_GET-style names cannot be written
// literally in a pattern.
fn rename_metavars(lang: &[u8], pattern: &[u8], out: &mut Vec<u8>) {
    let py = lang == b"python";
    let js = lang == b"javascript" || lang == b"typescript" || lang == b"tsx";
    let lua = lang == b"lua";
    let gd = lang == b"gdscript";
    let php = lang == b"php";
    let hash = py || gd || php; // # starts a comment (in PHP, not #[ attributes)
    let single = py || js || lua || gd || php; // '...' is a string, not a character
    let n = pattern.len();
    let mut i = 0;
    while i < n {
        let c = pattern[i];
        // A comment, copied as it is.
        // Lua: -- to the end of the line, --[[ ]] (or --[==[ ]==]) a block.
        if lua && c == b'-' && i + 1 < n && pattern[i + 1] == b'-' {
            let mut e = i + 2;
            let long = lua_long_bracket(pattern, e);
            if long > 0 {
                e = long;
            } else {
                while e < n && pattern[e] != b'\n' {
                    e += 1;
                }
            }
            out.extend_from_slice(&pattern[i..e]);
            i = e;
            continue;
        }
        // A Lua long string, [[ ]] or [==[ ]==].
        if lua && c == b'[' {
            let long = lua_long_bracket(pattern, i);
            if long > 0 {
                out.extend_from_slice(&pattern[i..long]);
                i = long;
                continue;
            }
        }
        let slash_comment = !py && !lua && !gd && c == b'/' && i + 1 < n && (pattern[i + 1] == b'/' || pattern[i + 1] == b'*');
        let hash_comment = hash && c == b'#' && !(php && i + 1 < n && pattern[i + 1] == b'[');
        if slash_comment || hash_comment {
            let line = hash_comment || pattern[i + 1] == b'/';
            let mut e = i + if hash_comment { 1 } else { 2 };
            while e < n && !(if line { pattern[e] == b'\n' } else { pattern[e] == b'/' && pattern[e - 1] == b'*' && e > i + 2 }) {
                e += 1;
            }
            if e < n && !line {
                e += 1;
            }
            out.extend_from_slice(&pattern[i..e]);
            i = e;
            continue;
        }
        // A Rust raw string, r"..." or r#"..."#, which may hold quotes.
        if lang == b"rust" && c == b'r' && (i == 0 || !is_word(&pattern[i - 1..i])) {
            let mut h = i + 1;
            while h < n && pattern[h] == b'#' {
                h += 1;
            }
            if h < n && pattern[h] == b'"' {
                let hashes = h - i - 1;
                let mut e = h + 1;
                loop {
                    if e >= n {
                        break;
                    }
                    if pattern[e] == b'"' {
                        let mut k = 0;
                        while k < hashes && e + 1 + k < n && pattern[e + 1 + k] == b'#' {
                            k += 1;
                        }
                        if k == hashes {
                            e += 1 + hashes;
                            break;
                        }
                    }
                    e += 1;
                }
                out.extend_from_slice(&pattern[i..e.min(n)]);
                i = e.min(n);
                continue;
            }
        }
        // C#: a raw string opens with three or more quotes and closes with as
        // many, so """" ... """" may hold """.
        if lang == b"csharp" && c == b'"' && i + 2 < n && pattern[i + 1] == b'"' && pattern[i + 2] == b'"' {
            let mut q = 0;
            while i + q < n && pattern[i + q] == b'"' {
                q += 1;
            }
            let mut e = i + q;
            let mut closed = false;
            while e < n && !closed {
                if pattern[e] == b'"' {
                    let mut run = 0;
                    while e + run < n && pattern[e + run] == b'"' {
                        run += 1;
                    }
                    if run >= q {
                        e += q;
                        closed = true;
                    } else {
                        e += run;
                    }
                } else {
                    e += 1;
                }
            }
            out.extend_from_slice(&pattern[i..e]);
            i = e;
            continue;
        }
        // A triple-quoted string (Python, and Kotlin and Java """), which may
        // hold its quote alone.
        let triple_ok = py || gd || ((lang == b"kotlin" || lang == b"java") && c == b'"');
        if triple_ok && (c == b'"' || c == b'\'') && i + 2 < n && pattern[i + 1] == c && pattern[i + 2] == c {
            let mut e = i + 3;
            while e < n && !(e + 2 < n && pattern[e] == c && pattern[e + 1] == c && pattern[e + 2] == c) {
                // Python and Java text blocks take escapes (\"""); Kotlin raw strings do not.
                e += if pattern[e] == b'\\' && lang != b"kotlin" { 2 } else { 1 };
            }
            // In Kotlin a run of more than three quotes closes with its last
            // three; Python and Java close at the first three.
            if lang == b"kotlin" {
                while e + 3 < n && pattern[e + 3] == c {
                    e += 1;
                }
            }
            e = (e + 3).min(n);
            out.extend_from_slice(&pattern[i..e]);
            i = e;
            continue;
        }
        // C#: a verbatim string, @"..." (or $@"..." / @$"..."), where a
        // backslash is text and "" is a quote.
        if lang == b"csharp" && (c == b'@' || c == b'$') && i + 1 < n {
            let mut q = i + 1;
            if q < n && (pattern[q] == b'@' || pattern[q] == b'$') && pattern[q] != c {
                q += 1;
            }
            let verbatim = c == b'@' || pattern[i + 1] == b'@';
            if verbatim && q < n && pattern[q] == b'"' {
                let mut e = q + 1;
                loop {
                    if e >= n {
                        break;
                    }
                    if pattern[e] == b'"' {
                        if e + 1 < n && pattern[e + 1] == b'"' {
                            e += 2;
                            continue;
                        }
                        e += 1;
                        break;
                    }
                    e += 1;
                }
                out.extend_from_slice(&pattern[i..e.min(n)]);
                i = e.min(n);
                continue;
            }
        }
        // PHP: a heredoc (<<<ID ... ID) or nowdoc (<<<'ID' ... ID), copied
        // as text up to the line that closes it.
        if php && c == b'<' && i + 3 < n && pattern[i + 1] == b'<' && pattern[i + 2] == b'<' {
            let mut j = i + 3;
            while j < n && (pattern[j] == b' ' || pattern[j] == b'\t') {
                j += 1;
            }
            let quoted = j < n && (pattern[j] == b'\'' || pattern[j] == b'"');
            if quoted {
                j += 1;
            }
            let id0 = j;
            while j < n && is_word(&pattern[j..j + 1]) {
                j += 1;
            }
            if j > id0 {
                let id = &pattern[id0..j];
                // The closing line: optional indentation, then the identifier.
                let mut e = j;
                let mut found = false;
                while !found && e < n {
                    let nl = find(&pattern[e..], b"\n");
                    if nl < 0 {
                        break;
                    }
                    let mut k = e + nl as usize + 1;
                    while k < n && (pattern[k] == b' ' || pattern[k] == b'\t') {
                        k += 1;
                    }
                    if pattern[k..].starts_with(id) && (k + id.len() == n || !is_word(&pattern[k + id.len()..k + id.len() + 1])) {
                        e = k + id.len();
                        found = true;
                    } else {
                        e = k;
                    }
                }
                let stop = if found { e } else { n };
                out.extend_from_slice(&pattern[i..stop]);
                i = stop;
                continue;
            }
        }
        // A string, copied as it is up to its unescaped closing quote.
        if c == b'"' || (single && c == b'\'') || (js && c == b'`') {
            let mut e = i + 1;
            while e < n && pattern[e] != c {
                e += if pattern[e] == b'\\' { 2 } else { 1 };
            }
            e = (e + 1).min(n);
            out.extend_from_slice(&pattern[i..e]);
            i = e;
            continue;
        }
        // A character: 'x' or '\x', but not a Rust lifetime ('a with no closing quote).
        if c == b'\'' {
            let k = if i + 2 < n && pattern[i + 2] == b'\'' {
                3
            } else if i + 3 < n && pattern[i + 1] == b'\\' && pattern[i + 3] == b'\'' {
                4
            } else {
                1
            };
            out.extend_from_slice(&pattern[i..i + k]);
            i += k;
            continue;
        }
        if c != b'$' {
            out.push(c);
            i += 1;
            continue;
        }
        let mut d = 0;
        while i + d < n && pattern[i + d] == b'$' {
            d += 1;
        }
        let mut e = i + d;
        while e < n && is_meta_char(pattern[e]) {
            e += 1;
        }
        if d == 3 {
            out.extend_from_slice(MVM);
            out.extend_from_slice(if e > i + d { &pattern[i + d..e] } else { b"_" });
        } else if d == 1 && e > i + 1 {
            out.extend_from_slice(MV);
            out.extend_from_slice(&pattern[i + 1..e]);
        } else {
            out.extend_from_slice(&pattern[i..e]);
        }
        i = e;
    }
}

// A GDScript pattern with a tab after each newline that is not inside a
// string ('...', "...", or a triple-quoted one) or a comment.
fn gd_indent(p: &[u8], out: &mut Vec<u8>) {
    let n = p.len();
    let mut i = 0;
    while i < n {
        let c = p[i];
        if c == b'#' {
            while i < n && p[i] != b'\n' {
                out.push(p[i]);
                i += 1;
            }
            continue;
        }
        if c == b'"' || c == b'\'' {
            let triple = i + 2 < n && p[i + 1] == c && p[i + 2] == c;
            let mut e = i + if triple { 3 } else { 1 };
            loop {
                if e >= n {
                    break;
                }
                if p[e] == b'\\' {
                    e += 2;
                    continue;
                }
                if triple && e + 2 < n && p[e] == c && p[e + 1] == c && p[e + 2] == c {
                    e += 3;
                    break;
                }
                if !triple && (p[e] == c || p[e] == b'\n') {
                    e += 1;
                    break;
                }
                e += 1;
            }
            e = e.min(n);
            out.extend_from_slice(&p[i..e]);
            i = e;
            continue;
        }
        out.push(c);
        if c == b'\n' {
            out.push(b'\t');
        }
        i += 1;
    }
}

// Contexts a pattern is parsed in, first that parses: alone (a whole file),
// as a statement inside a function, as a class member. Rust, Java and C only
// take items at the top of a file, so `$X.unwrap()` needs the function.
fn context(k: usize) -> (&'static [u8], &'static [u8]) {
    match k {
        1 => (b"fn zswan_ctx() {\n", b"\n}"),
        2 => (b"void zswan_ctx() {\n", b";\n}"),
        3 => (b"class ZSwanCtx { void zswan_ctx() {\n", b";\n} }"),
        4 => (b"class ZSwanCtx {\n", b"\n}"),
        5 => (b"<?php\n", b""), // PHP code needs its opening tag
        6 => (b"<?php\nfunction zswan_ctx() {\n", b";\n}"),
        7 => (b"func zswan_ctx():\n\t", b""), // GDScript: a statement in a function
        8 => (b"fn zswan_ctx() {\n", b";\n}"), // WGSL: statements end in ;
        9 => (b"fn zswan_ctx() {\nlet zswan_v = ", b";\n}"), // WGSL: an expression
        _ => (b"", b""),
    }
}

/// A compiled pattern: its text (in the context it parsed in), its tree, the
/// node that is the pattern, its language, and the words a file must hold.
#[derive(Default, Clone)]
pub struct Pattern {
    p_text: Vec<u8>,
    p_nodes: Vec<i32>,
    p_root: i64,
    p_lang: Vec<u8>,
    p_words: Vec<u8>, // one per line
}

/// One match in a file: its bytes and start (0-based row and column), and
/// its captures as name 0x1f text 0x1e, in the order they were bound.
pub struct Match {
    pub start: i64,
    pub end: i64,
    pub row: i64,
    pub col: i64,
    pub captures: Vec<u8>,
}

impl Pattern {
    fn ptext(&self, i: i64) -> &[u8] {
        &self.p_text[start(&self.p_nodes, i) as usize..end(&self.p_nodes, i) as usize]
    }

    // The only named child of a wrapper (an expression statement: one named
    // child, nothing else but a `;`), or -1.
    fn wrapped(&self, p: i64) -> i64 {
        let n = &self.p_nodes;
        let mut only: i64 = -1;
        let mut named = 0;
        let mut c = first(n, p);
        while c >= 0 {
            if (flags(n, c) & F_EXTRA as i64) == 0 {
                if (flags(n, c) & F_NAMED as i64) != 0 {
                    named += 1;
                    only = c;
                } else if self.ptext(c) != b";" {
                    return -1;
                }
            }
            c = next(n, c);
        }
        if named == 1 {
            only
        } else {
            -1
        }
    }

    // 1 for $X, 3 for $$$X, 0 otherwise; the name goes in `name`. A
    // metavariable is a named leaf, an error node holding only one, or a
    // statement wrapping one (`$$$B` alone in a block is an expression
    // statement).
    fn meta(&self, p: i64, name: &mut Vec<u8>) -> i64 {
        let n = &self.p_nodes;
        let leaf = first(n, p) < 0 && (flags(n, p) & F_NAMED as i64) != 0;
        if !leaf && (flags(n, p) & F_ERROR as i64) == 0 {
            let w = self.wrapped(p);
            return if w >= 0 { self.meta(w, name) } else { 0 };
        }
        let s = trim(self.ptext(p));
        if !is_word(s) {
            return 0;
        }
        if s.starts_with(MVM) {
            name.clear();
            name.extend_from_slice(&s[MVM.len()..]);
            return 3;
        }
        if s.starts_with(MV) {
            name.clear();
            name.extend_from_slice(&s[MV.len()..]);
            return 1;
        }
        0
    }

    // Whether a pattern node holds only punctuation and metavariables, one of
    // them a $$$ run: `{ $$$B }` say. A grammar can give such a node another kind than the code it
    // stands for (Kotlin parses it as a lambda-like block rather than a class
    // body), so it matches by its punctuation and metavariables alone.
    fn only_holes(&self, p: i64) -> bool {
        let n = &self.p_nodes;
        let mut c = solid(n, first(n, p));
        let mut holes = 0;
        let mut name: Vec<u8> = Vec::new();
        while c >= 0 {
            let m = self.meta(c, &mut name);
            if m == 3 {
                holes += 1;
            } else if m == 1 {
            } else if (flags(n, c) & F_NAMED as i64) != 0 {
                return false;
            }
            c = solid(n, next(n, c));
        }
        holes > 0
    }

    /// Compiles a pattern for a language. False, with why, when the language
    /// has no grammar or the pattern does not parse as code.
    pub fn compile(&mut self, lang: &[u8], pattern: &[u8], why: &mut Vec<u8>) -> bool {
        self.p_words.clear();
        let mut renamed: Vec<u8> = Vec::new();
        rename_metavars(lang, trim(pattern), &mut renamed);
        self.p_lang = lang.to_vec();
        for k in 0..10 {
            // Outside <?php, PHP's grammar reads text as HTML, which "parses";
            // a PHP pattern is only ever read as PHP.
            if lang == b"php" && k < 5 {
                continue;
            }
            let (pre, post) = context(k);
            if k == 7 && lang == b"gdscript" && find(&renamed, b"\n") >= 0 {
                // Every further line of a GDScript pattern goes inside the function
                // too; a newline inside a string is text and stays as it is.
                let mut ind: Vec<u8> = Vec::new();
                gd_indent(&renamed, &mut ind);
                renamed = ind;
            }
            let text: Vec<u8> = [pre, &renamed[..], post].concat();
            if !parse(lang, &text, &mut self.p_nodes) {
                why.extend_from_slice(b"no tree-sitter grammar for ");
                why.extend_from_slice(lang);
                return false;
            }
            let n = (self.p_nodes.len() / R) as i64;
            let nodes = &self.p_nodes;
            // An error that is only a metavariable is fine: `{ $$$B }` where the
            // grammar wants items, say. It stands for whatever is there.
            let mut bad = false;
            for i in 0..n {
                if (flags(nodes, i) & F_ERROR as i64) != 0 {
                    let t = trim(&text[start(nodes, i) as usize..end(nodes, i) as usize]);
                    if !(t.starts_with(b"zswan_mv") && is_word(t)) {
                        bad = true;
                    }
                }
            }
            // The outermost node that is exactly the pattern (or it and a `;`).
            let mut at: i64 = -1;
            let a = pre.len() as i64;
            let b = a + renamed.len() as i64;
            if !bad {
                for i in 0..n {
                    if at < 0 && start(nodes, i) == a && (end(nodes, i) == b || end(nodes, i) == b + 1) {
                        at = i;
                    }
                }
            }
            if at >= 0 {
                self.p_text = text.clone();
                // Down through wrappers (an expression statement): one named
                // child, and nothing else but a `;`.
                loop {
                    let w = self.wrapped(at);
                    if w < 0 {
                        break;
                    }
                    at = w;
                }
                self.p_root = at;
                // The words a file must hold to match: those of the pattern's
                // own leaves, not its comments (skipped in matching) nor its
                // metavariables.
                let nodes = &self.p_nodes;
                let mut words: Vec<u8> = Vec::new();
                for i in 0..n {
                    if first(nodes, i) < 0
                        && (flags(nodes, i) & (F_EXTRA | F_ERROR) as i64) != F_EXTRA as i64
                        && start(nodes, i) >= a
                        && end(nodes, i) <= b
                    {
                        let leaf = &text[start(nodes, i) as usize..end(nodes, i) as usize];
                        let mut j = 0;
                        while j < leaf.len() {
                            let c = leaf[j];
                            let starts = c.is_ascii_lowercase() || c.is_ascii_uppercase() || c == b'_';
                            if !starts {
                                j += 1;
                                continue;
                            }
                            let mut e = j;
                            while e < leaf.len() && is_word(&leaf[e..e + 1]) {
                                e += 1;
                            }
                            if !leaf[j..e].starts_with(b"zswan_mv") {
                                words.extend_from_slice(&leaf[j..e]);
                                words.push(b'\n');
                            }
                            j = e;
                        }
                    }
                }
                self.p_words = words;
                return true;
            }
        }
        why.extend_from_slice(b"the pattern does not parse as ");
        why.extend_from_slice(lang);
        false
    }

    /// Whether src can hold a match at all: it has every word the pattern has.
    pub fn might_match(&self, src: &[u8]) -> bool {
        self.p_words.split(|&c| c == b'\n').all(|w| w.is_empty() || find(src, w) >= 0)
    }

    /// The matches in one file's text, in source order (search_worker).
    pub fn search_text(&self, text: &[u8]) -> Vec<Match> {
        let mut out: Vec<Match> = Vec::new();
        if !self.might_match(text) {
            return out;
        }
        let mut t_nodes: Vec<i32> = Vec::new();
        if !parse(&self.p_lang, text, &mut t_nodes) {
            return out;
        }
        let mut m = Matcher { p: self, t_text: text, t_nodes: &t_nodes, binds: Vec::new() };
        for i in 0..(t_nodes.len() / R) as i64 {
            m.binds.clear();
            if (flags(&t_nodes, i) & F_EXTRA as i64) == 0 && m.match_node(self.p_root, i) {
                let mut caps: Vec<u8> = Vec::new();
                for b in &m.binds {
                    caps.extend_from_slice(&b.name);
                    caps.push(0x1f);
                    caps.extend_from_slice(m.span_text(b.a, b.b));
                    caps.push(0x1e);
                }
                out.push(Match {
                    start: start(&t_nodes, i),
                    end: end(&t_nodes, i),
                    row: row(&t_nodes, i),
                    col: col(&t_nodes, i),
                    captures: caps,
                });
            }
        }
        out
    }

    /// Searches the files (absolute paths) on every core, as search_files
    /// does with Goose threads, and gives each file's matches, in file order.
    pub fn search_files(&self, paths: &[&[u8]]) -> Vec<Vec<Match>> {
        use std::os::unix::ffi::OsStrExt;
        use std::sync::atomic::{AtomicUsize, Ordering};
        let n = paths.len();
        let mut results: Vec<Option<Vec<Match>>> = (0..n).map(|_| None).collect();
        if n == 0 {
            return Vec::new();
        }
        let hw = std::thread::available_parallelism().map(|v| v.get()).unwrap_or(1);
        let workers = hw.min(16).min(n).max(1);
        let next = AtomicUsize::new(0);
        let done: std::sync::Mutex<Vec<(usize, Vec<Match>)>> = std::sync::Mutex::new(Vec::new());
        std::thread::scope(|s| {
            for _ in 0..workers {
                s.spawn(|| loop {
                    let k = next.fetch_add(1, Ordering::Relaxed);
                    if k >= n {
                        break;
                    }
                    let found = match std::fs::read(std::ffi::OsStr::from_bytes(paths[k])) {
                        Ok(text) => self.search_text(&text),
                        Err(_) => Vec::new(),
                    };
                    done.lock().unwrap().push((k, found));
                });
            }
        });
        for (k, found) in done.into_inner().unwrap() {
            results[k] = Some(found);
        }
        results.into_iter().map(|r| r.unwrap_or_default()).collect()
    }
}

struct Bind {
    name: Vec<u8>,
    a: i64, // target nodes a..b (inclusive); a < 0: none
    b: i64,
}

// One target tree being matched: the binds made so far (backtracking cuts
// them back).
struct Matcher<'a> {
    p: &'a Pattern,
    t_text: &'a [u8],
    t_nodes: &'a [i32],
    binds: Vec<Bind>,
}

impl Matcher<'_> {
    fn ttext(&self, i: i64) -> &[u8] {
        &self.t_text[start(self.t_nodes, i) as usize..end(self.t_nodes, i) as usize]
    }

    fn span_text(&self, a: i64, b: i64) -> &[u8] {
        if a < 0 {
            return &self.t_text[0..0];
        }
        &self.t_text[start(self.t_nodes, a) as usize..end(self.t_nodes, b) as usize]
    }

    fn bind(&mut self, name: &[u8], a: i64, b: i64) -> bool {
        if !name.is_empty() && name[0] == b'_' {
            return true; // anonymous
        }
        for k in 0..self.binds.len() {
            if self.binds[k].name == name {
                let (x, y) = (self.binds[k].a, self.binds[k].b);
                return self.span_text(x, y) == self.span_text(a, b);
            }
        }
        self.binds.push(Bind { name: name.to_vec(), a, b });
        true
    }

    fn unnamed(&self, t: i64) -> bool {
        t >= 0 && (flags(self.t_nodes, t) & F_NAMED as i64) == 0
    }

    fn match_node(&mut self, p: i64, t: i64) -> bool {
        let pat = self.p;
        let pn = &pat.p_nodes;
        let tn = self.t_nodes;
        let mut name: Vec<u8> = Vec::new();
        if pat.meta(p, &mut name) == 1 {
            // $X is one named node
            return (flags(tn, t) & F_NAMED as i64) != 0 && self.bind(&name, t, t);
        }
        if !(sym(pn, p) == sym(tn, t) || (first(tn, t) >= 0 && (flags(tn, t) & F_NAMED as i64) != 0 && pat.only_holes(p))) {
            return false;
        }
        if first(pn, p) < 0 {
            return pat.ptext(p) == self.ttext(t);
        }
        self.match_seq(solid(pn, first(pn, p)), solid(tn, first(tn, t)))
    }

    // Pattern siblings from p against target siblings from t. As ast-grep's
    // default ("smart") does, punctuation in the target that the pattern leaves
    // out is skipped (`return $X` matches `return x;`), and once the pattern's
    // siblings are used up the target's remaining ones are allowed (`if ($C) {
    // $$$B }` matches an if with an else; `const $X = $V` a declaration of two).
    fn match_seq(&mut self, p: i64, t: i64) -> bool {
        if p < 0 {
            return true;
        }
        let pat = self.p;
        let pnodes = &pat.p_nodes;
        let tn = self.t_nodes;
        let mark = self.binds.len();
        let pn = solid(pnodes, next(pnodes, p));
        let mut name: Vec<u8> = Vec::new();
        if pat.meta(p, &mut name) == 3 {
            if self.bind(&name, -1, -1) && self.match_seq(pn, t) {
                return true;
            }
            self.binds.truncate(mark);
            // An empty list capture has no following separator: `{ $$$A, key:
            // value }` must also match `{ key: value }`. Only an empty capture
            // may omit the comma; ordinary punctuation still has to match.
            if pn >= 0 && (flags(pnodes, pn) & F_NAMED as i64) == 0 && pat.ptext(pn) == b"," {
                if self.bind(&name, -1, -1) && self.match_seq(solid(pnodes, next(pnodes, pn)), t) {
                    return true;
                }
                self.binds.truncate(mark);
            }
            let mut last = t;
            while last >= 0 {
                if self.bind(&name, t, last) && self.match_seq(pn, solid(tn, next(tn, last))) {
                    return true;
                }
                self.binds.truncate(mark);
                last = solid(tn, next(tn, last));
            }
            return false;
        }
        // Likewise the separator before an empty trailing capture disappears:
        // `call($X, $$$A)` matches `call(x)`, with A bound to empty text.
        if (flags(pnodes, p) & F_NAMED as i64) == 0 && pat.ptext(p) == b"," && pn >= 0 && pat.meta(pn, &mut name) == 3 {
            if self.bind(&name, -1, -1) && self.match_seq(solid(pnodes, next(pnodes, pn)), t) {
                return true;
            }
            self.binds.truncate(mark);
        }
        if t < 0 {
            return false;
        }
        if self.match_node(p, t) && self.match_seq(pn, solid(tn, next(tn, t))) {
            return true;
        }
        self.binds.truncate(mark);
        if self.unnamed(t) && self.match_seq(p, solid(tn, next(tn, t))) {
            return true;
        }
        self.binds.truncate(mark);
        false
    }
}
