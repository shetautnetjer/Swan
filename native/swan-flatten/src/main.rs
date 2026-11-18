// swan-flatten: Rust port of tools/scip-flatten.ts. Flattens SCIP index files
// (protobuf) into the same TSV files, byte for byte, using every core.
//
//   swan-flatten [--fresh <list>] [--texts <tsv>] [--root <repo>] [--ignored <list>] <index.scip[=base]> <out-dir> [more.scip[=base] ...]
//
// The protobuf reader is hand written, like the TypeScript one, so unknown
// fields, varints and truncation behave the same. JS semantics that reach the
// output (UTF-16 string lengths and columns, number formatting, regex
// backtracking, TextDecoder, path.posix) are reproduced by hand below.

use rayon::prelude::*;
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};
use std::io::Write;
use std::sync::OnceLock;

// ---------------------------------------------------------------- hashing

#[derive(Default, Clone, Copy)]
struct Fx(u64);
impl Hasher for Fx {
    fn finish(&self) -> u64 {
        (self.0 ^ (self.0 >> 29)).wrapping_mul(0x9E3779B97F4A7C15)
    }
    fn write(&mut self, bytes: &[u8]) {
        let mut h = self.0;
        let mut chunks = bytes.chunks_exact(8);
        for c in &mut chunks {
            h = (h.rotate_left(5) ^ u64::from_le_bytes(c.try_into().unwrap())).wrapping_mul(0x517cc1b727220a95);
        }
        for &b in chunks.remainder() {
            h = (h.rotate_left(5) ^ b as u64).wrapping_mul(0x517cc1b727220a95);
        }
        self.0 = h;
    }
    fn write_u64(&mut self, i: u64) {
        self.0 = (self.0.rotate_left(5) ^ i).wrapping_mul(0x517cc1b727220a95);
    }
    fn write_usize(&mut self, i: usize) {
        self.write_u64(i as u64)
    }
}
type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;
type FxSet<K> = HashSet<K, BuildHasherDefault<Fx>>;

// ------------------------------------------------------------ JS helpers

fn is_js_ws(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{d}' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}'
            | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}
fn is_js_ws16(u: u16) -> bool {
    char::from_u32(u as u32).map_or(false, is_js_ws)
}
fn is_lt(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}
fn is_lt16(u: u16) -> bool {
    matches!(u, 0x0a | 0x0d | 0x2028 | 0x2029)
}
fn js_trim(s: &str) -> &str {
    s.trim_matches(is_js_ws)
}
fn is_word16(u: u16) -> bool {
    matches!(u, 0x30..=0x39 | 0x41..=0x5a | 0x61..=0x7a | 0x5f)
}
fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn push_u64(out: &mut Vec<u8>, mut n: u64) {
    let mut tmp = [0u8; 20];
    let mut i = 20;
    if n == 0 {
        out.push(b'0');
        return;
    }
    while n > 0 {
        i -= 1;
        tmp[i] = b'0' + (n % 10) as u8;
        n /= 10;
    }
    out.extend_from_slice(&tmp[i..]);
}

fn js_num_string(v: f64) -> String {
    if v.is_nan() {
        return "NaN".into();
    }
    if v == 0.0 {
        return "0".into();
    }
    if v.is_infinite() {
        return if v > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    let neg = v < 0.0;
    let s = format!("{:e}", v.abs());
    let (mant, exp) = s.split_once('e').unwrap();
    let exp: i32 = exp.parse().unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let k = digits.len() as i32;
    let n = exp + 1;
    let mut r = String::new();
    if neg {
        r.push('-');
    }
    if k <= n && n <= 21 {
        r.push_str(&digits);
        for _ in 0..(n - k) {
            r.push('0');
        }
    } else if 0 < n && n <= 21 {
        r.push_str(&digits[..n as usize]);
        r.push('.');
        r.push_str(&digits[n as usize..]);
    } else if -6 < n && n <= 0 {
        r.push_str("0.");
        for _ in 0..(-n) {
            r.push('0');
        }
        r.push_str(&digits);
    } else {
        let e = n - 1;
        r.push_str(&digits[..1]);
        if k > 1 {
            r.push('.');
            r.push_str(&digits[1..]);
        }
        r.push('e');
        r.push(if e < 0 { '-' } else { '+' });
        r.push_str(&e.abs().to_string());
    }
    r
}
fn push_num(out: &mut Vec<u8>, v: f64) {
    if v >= 0.0 && v < 9007199254740992.0 && v.fract() == 0.0 {
        push_u64(out, v as u64);
    } else {
        out.extend_from_slice(js_num_string(v).as_bytes());
    }
}
fn num_string(v: f64) -> String {
    let mut o = Vec::new();
    push_num(&mut o, v);
    String::from_utf8(o).unwrap()
}

fn to_int32_bits(v: f64) -> u32 {
    if !v.is_finite() {
        return 0;
    }
    v.trunc().rem_euclid(4294967296.0) as u32
}

// s.slice(0, n) in UTF-16 units, then written as UTF-8 (a cut surrogate pair
// leaves a lone surrogate, which the file writer turns into U+FFFD).
fn slice16(s: &str, n: usize) -> String {
    let mut units = 0usize;
    let mut out = String::new();
    for c in s.chars() {
        let l = c.len_utf16();
        if units + l > n {
            if units < n {
                out.push('\u{FFFD}');
            }
            return out;
        }
        units += l;
        out.push(c);
    }
    out
}

// ------------------------------------------------------------ posix paths

fn norm_segments(path: &str, allow_above: bool) -> Vec<&str> {
    let mut st: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            if !st.is_empty() && *st.last().unwrap() != ".." {
                st.pop();
            } else if allow_above {
                st.push("..");
            }
        } else {
            st.push(seg);
        }
    }
    st
}
fn posix_normalize(p: &str) -> String {
    if p.is_empty() {
        return ".".into();
    }
    let abs = p.starts_with('/');
    let trailing = p.ends_with('/');
    let mut s = norm_segments(p, !abs).join("/");
    if s.is_empty() {
        if abs {
            return "/".into();
        }
        return if trailing { "./".into() } else { ".".into() };
    }
    if trailing {
        s.push('/');
    }
    if abs {
        format!("/{s}")
    } else {
        s
    }
}
fn posix_join(args: &[&str]) -> String {
    let parts: Vec<&str> = args.iter().copied().filter(|a| !a.is_empty()).collect();
    if parts.is_empty() {
        return ".".into();
    }
    posix_normalize(&parts.join("/"))
}
fn posix_resolve(p: &str) -> String {
    let cwd = std::env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let mut resolved = String::new();
    let mut abs = false;
    for path in [p, cwd.as_str()] {
        if path.is_empty() {
            continue;
        }
        resolved = format!("{path}/{resolved}");
        abs = path.starts_with('/');
        if abs {
            break;
        }
    }
    let s = norm_segments(&resolved, !abs).join("/");
    if abs {
        format!("/{s}")
    } else if s.is_empty() {
        ".".into()
    } else {
        s
    }
}
fn posix_relative(from: &str, to: &str) -> String {
    let f = posix_resolve(from);
    let t = posix_resolve(to);
    if f == t {
        return String::new();
    }
    let fs: Vec<&str> = f.split('/').filter(|s| !s.is_empty()).collect();
    let ts: Vec<&str> = t.split('/').filter(|s| !s.is_empty()).collect();
    let mut c = 0;
    while c < fs.len() && c < ts.len() && fs[c] == ts[c] {
        c += 1;
    }
    let mut parts: Vec<&str> = Vec::new();
    for _ in c..fs.len() {
        parts.push("..");
    }
    parts.extend_from_slice(&ts[c..]);
    parts.join("/")
}
fn decode_uri_component(s: &str) -> Result<String, ()> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            if i + 2 >= b.len() {
                return Err(());
            }
            let h = |c: u8| (c as char).to_digit(16);
            match (h(b[i + 1]), h(b[i + 2])) {
                (Some(a), Some(c)) => out.push((a * 16 + c) as u8),
                _ => return Err(()),
            }
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| ())
}

// ---------------------------------------------------------------- context

struct Ctx {
    repo_root: String,
    abs_prefix: String,
    fresh: Option<HashSet<String>>,
    kept: HashMap<String, String>,
    // Folders git ignores, each "dir/": a document under one is left out,
    // whichever indexer wrote it (some find their own sources).
    ignored: Vec<String>,
}
static CTX: OnceLock<Ctx> = OnceLock::new();
fn ctx() -> &'static Ctx {
    CTX.get().unwrap()
}

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1)
}

// ------------------------------------------------------- protobuf reader

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
    end: usize,
}
fn f64_to_usize(v: f64) -> usize {
    if v.is_nan() || v < 0.0 {
        0
    } else if v >= 1.8e19 {
        usize::MAX
    } else {
        v as usize
    }
}
impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0, end: buf.len() }
    }
    fn varint(&mut self) -> f64 {
        let mut result = 0.0f64;
        let mut shift: i32 = 0;
        loop {
            let b = self.buf.get(self.pos).copied().unwrap_or(0);
            self.pos = self.pos.saturating_add(1);
            result += ((b & 0x7f) as f64) * 2f64.powi(shift);
            shift += 7;
            if b & 0x80 == 0 {
                break;
            }
        }
        result
    }
    fn fields<F: FnMut(u64, u32, &mut Reader<'a>)>(&mut self, mut f: F) {
        loop {
            let limit = self.end.min(self.buf.len());
            if self.pos >= limit {
                break;
            }
            let key = self.varint();
            let field = f64_to_usize((key / 8.0).floor()) as u64;
            let wt = ((key % 4294967296.0) as u32) & 7;
            if wt == 2 {
                let len = f64_to_usize(self.varint());
                let mut sub = Reader { buf: self.buf, pos: self.pos, end: self.pos.saturating_add(len) };
                f(field, wt, &mut sub);
                self.pos = self.pos.saturating_add(len);
            } else if wt == 0 {
                let start = self.pos;
                f(field, wt, self);
                if self.pos == start {
                    self.varint();
                }
            } else if wt == 1 {
                self.pos = self.pos.saturating_add(8);
            } else if wt == 5 {
                self.pos = self.pos.saturating_add(4);
            } else {
                die(&format!("Error: unsupported wire type {wt} at {}", self.pos));
            }
        }
    }
    fn raw(&self) -> &'a [u8] {
        let s = self.pos.min(self.buf.len());
        let e = self.end.min(self.buf.len());
        if s >= e {
            &[]
        } else {
            &self.buf[s..e]
        }
    }
    fn string(&self) -> Cow<'a, str> {
        decode_utf8(self.raw())
    }
}
// TextDecoder("utf-8"): a leading BOM is dropped, bad bytes become U+FFFD.
fn decode_utf8(b: &[u8]) -> Cow<'_, str> {
    let b = if b.starts_with(&[0xEF, 0xBB, 0xBF]) { &b[3..] } else { b };
    String::from_utf8_lossy(b)
}

// ------------------------------------------------------------- cleaning

fn clean_text(s: &str) -> String {
    let ap = &ctx().abs_prefix;
    let t: Cow<str> = if !ap.is_empty() && s.contains(ap.as_str()) {
        Cow::Owned(s.replace(ap.as_str(), " "))
    } else {
        Cow::Borrowed(s)
    };
    if t.bytes().any(|b| b == b'\t' || b == b'\n' || b == b'\r') {
        t.chars().map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c }).collect()
    } else {
        t.into_owned()
    }
}
fn strip_type_literal_digits(s: &str, out: &mut String) {
    let mut rest = s;
    while let Some(i) = rest.find("typeLiteral") {
        let after = i + "typeLiteral".len();
        out.push_str(&rest[..after]);
        let tail = &rest[after..];
        let d = tail.bytes().take_while(|b| b.is_ascii_digit()).count();
        rest = &tail[d..];
    }
    out.push_str(rest);
}
// Regex /(`(?:[^`]|``)*`)/ at a backtick: end of the match, if any.
fn quoted_end(b: &[u8], i: usize) -> Option<usize> {
    let n = b.len();
    let mut p = i + 1;
    let mut last_pair: Option<usize> = None;
    loop {
        if p >= n {
            return last_pair.map(|q| q + 1);
        }
        if b[p] != b'`' {
            p += 1;
        } else if p + 1 < n && b[p + 1] == b'`' {
            last_pair = Some(p);
            p += 2;
        } else {
            return Some(p + 1);
        }
    }
}
fn clean(s: &str) -> String {
    let t = clean_text(s);
    if !t.contains("typeLiteral") {
        return t;
    }
    let b = t.as_bytes();
    let mut out = String::with_capacity(t.len());
    let mut pos = 0;
    let mut search = 0;
    loop {
        let start = b[search..].iter().position(|&c| c == b'`').map(|x| x + search);
        let Some(i) = start else { break };
        match quoted_end(b, i) {
            Some(e) => {
                strip_type_literal_digits(&t[pos..i], &mut out);
                out.push_str(&t[i..e]);
                pos = e;
                search = e;
            }
            None => break,
        }
    }
    strip_type_literal_digits(&t[pos..], &mut out);
    out
}

fn bare_name(n: &str) -> String {
    let mut s = n;
    if s.starts_with('`') {
        s = &s[1..];
    }
    if s.ends_with('`') {
        s = &s[..s.len() - 1];
    }
    if let Some(i) = s.find('<') {
        s = &s[..i];
    }
    js_trim(s).to_string()
}

// /```[\s\S]*?```/g then /^\s*---\s*$/gm then trim
fn prose_of(text: &str) -> String {
    let mut a = String::with_capacity(text.len());
    let mut rest = text;
    loop {
        match rest.find("```") {
            None => {
                a.push_str(rest);
                break;
            }
            Some(i) => match rest[i + 3..].find("```") {
                None => {
                    a.push_str(rest);
                    break;
                }
                Some(j) => {
                    a.push_str(&rest[..i]);
                    rest = &rest[i + 3 + j + 3..];
                }
            },
        }
    }
    let ch: Vec<char> = a.chars().collect();
    let n = ch.len();
    let mut out = String::with_capacity(a.len());
    let mut last = 0;
    let mut i = 0;
    while i <= n {
        if i == 0 || is_lt(ch[i - 1]) {
            let mut p = i;
            while p < n && is_js_ws(ch[p]) {
                p += 1;
            }
            if p + 3 <= n && ch[p] == '-' && ch[p + 1] == '-' && ch[p + 2] == '-' {
                let q = p + 3;
                let mut w = q;
                while w < n && is_js_ws(ch[w]) {
                    w += 1;
                }
                let mut e = w;
                let mut found = false;
                loop {
                    if e == n || is_lt(ch[e]) {
                        found = true;
                        break;
                    }
                    if e == q {
                        break;
                    }
                    e -= 1;
                }
                if found {
                    out.extend(ch[last..i].iter());
                    last = e;
                    i = e;
                    continue;
                }
            }
        }
        i += 1;
    }
    out.extend(ch[last.min(n)..].iter());
    js_trim(&out).to_string()
}
fn first_doc_line(text: &str) -> String {
    text.split('\n')
        .find(|l| !js_trim(l).is_empty() && !l.starts_with("```"))
        .unwrap_or("")
        .to_string()
}

// RUST_TRAIT_IMPL = /^(.*\/)impl#\[(`[^`]*`|[^\]]*)\]\[(`[^`]*`|[^\]]*)\](.*)$/
fn group_opts(ch: &[char], q: usize) -> Vec<usize> {
    let n = ch.len();
    let mut opts = Vec::new();
    if q < n && ch[q] == '`' {
        if let Some(j) = ch[q + 1..].iter().position(|&c| c == '`') {
            opts.push(q + 1 + j + 1);
        }
    }
    let mut e = q;
    while e < n && ch[e] != ']' {
        e += 1;
    }
    opts.push(e);
    opts
}
fn rust_trait_impl(sym: &str) -> Option<(String, String, String)> {
    let ch: Vec<char> = sym.chars().collect();
    let n = ch.len();
    let first_lt = ch.iter().position(|c| is_lt(*c)).unwrap_or(n);
    let pat: Vec<char> = "impl#[".chars().collect();
    for p in (0..first_lt).rev() {
        if ch[p] != '/' {
            continue;
        }
        let q = p + 1;
        if ch.len() < q + pat.len() || ch[q..q + pat.len()] != pat[..] {
            continue;
        }
        let q = q + pat.len();
        for g2 in group_opts(&ch, q) {
            if g2 + 1 < n && ch[g2] == ']' && ch[g2 + 1] == '[' {
                let q3 = g2 + 2;
                for g3 in group_opts(&ch, q3) {
                    if g3 < n && ch[g3] == ']' {
                        let tail = g3 + 1;
                        if !ch[tail..].iter().any(|c| is_lt(*c)) {
                            return Some((
                                ch[q..g2].iter().collect(),
                                ch[q3..g3].iter().collect(),
                                ch[tail..].iter().collect(),
                            ));
                        }
                    }
                }
            }
        }
    }
    None
}

// /([A-Za-z_][A-Za-z0-9_]*|`[^`]*`)(?:\(\)\.|[#.])$/ on a symbol, bareName'd.
fn last_name(sym: &str) -> String {
    let ch: Vec<char> = sym.chars().collect();
    let n = ch.len();
    let e = if sym.ends_with("().") {
        n - 3
    } else if sym.ends_with('#') || sym.ends_with('.') {
        n - 1
    } else {
        return String::new();
    };
    if e == 0 {
        return String::new();
    }
    if ch[e - 1] == '`' {
        if e >= 2 {
            let mut i = e - 2;
            loop {
                if ch[i] == '`' {
                    let g: String = ch[i..e].iter().collect();
                    return bare_name(&g);
                }
                if i == 0 {
                    break;
                }
                i -= 1;
            }
        }
        return String::new();
    }
    let mut r = e;
    while r > 0 && is_word_char(ch[r - 1]) {
        r -= 1;
    }
    for i in r..e {
        if ch[i].is_ascii_alphabetic() || ch[i] == '_' {
            let g: String = ch[i..e].iter().collect();
            return bare_name(&g);
        }
    }
    String::new()
}

// ------------------------------------------------------------ data model

const F_EMPTY: u16 = 1;
const F_LOCAL: u16 = 2;
const F_RA: u16 = 4;
const F_CXX: u16 = 8;
const F_DOTNET: u16 = 16;
const F_SWAN: u16 = 32;
const F_ENDS_HASH: u16 = 64;
const F_CDEF_END: u16 = 128;

struct SymEntry {
    s: String,
    flags: u16,
}
fn make_entry(s: String) -> SymEntry {
    let mut flags = 0;
    if s.is_empty() {
        flags |= F_EMPTY;
    }
    if s.starts_with("local ") {
        flags |= F_LOCAL;
    }
    if s.starts_with("rust-analyzer ") {
        flags |= F_RA;
    }
    if s.starts_with("cxx ") {
        flags |= F_CXX;
    }
    if s.starts_with("scip-dotnet ") {
        flags |= F_DOTNET;
    }
    if s.starts_with("swan-syntax ") {
        flags |= F_SWAN;
    }
    if s.ends_with('#') {
        flags |= F_ENDS_HASH;
    }
    if s.ends_with(").") || s.ends_with('#') {
        flags |= F_CDEF_END;
    }
    SymEntry { s, flags }
}

const R_DEF: u8 = 0;
const R_IMP: u8 = 1;
const R_NAME: u8 = 2;
const R_REF: u8 = 3;
const ROLE_STR: [&str; 4] = ["def", "imp", "name", "ref"];

#[derive(Clone, Copy)]
struct Row {
    sym: u32,
    n: u8,
    role: u8,
    nums: [f64; 4],
}
struct ExtRow {
    sym: u32,
    nums: [f64; 4],
}
struct CDef {
    sym: u32,
    line: Option<f64>,
    col: Option<f64>,
    cs: bool,
}
struct Pending {
    range: Vec<f64>,
    enclosing: Vec<f64>,
    sym: u32,
    roles: u32,
}
type Rel = [String; 4];

#[derive(Default)]
struct DocOut {
    path: String,
    fresh: bool,
    tab: Vec<SymEntry>,
    rows: Vec<Row>,
    ext: Vec<ExtRow>,
    defined: Vec<u32>,
    cdefs: Vec<CDef>,
    taken: Option<FxSet<u64>>,
    syms: Vec<(String, String)>,
    rels: Vec<Rel>,
}

fn span_of(r: &[f64]) -> ([f64; 4], u8) {
    if r.len() == 3 {
        ([r[0], r[1], r[0], r[2]], 4)
    } else {
        let n = r.len().min(4);
        let mut a = [0.0; 4];
        a[..n].copy_from_slice(&r[..n]);
        (a, n as u8)
    }
}
fn pos_key(l: f64, c: f64) -> Option<u64> {
    if l.is_finite() && c.is_finite() && l >= 0.0 && c >= 0.0 && l.fract() == 0.0 && c.fract() == 0.0 && l < 4e9 && c < 4e9 {
        Some(((l as u64) << 32) | c as u64)
    } else {
        None
    }
}

// ------------------------------------------------------------ symbolInfo

fn symbol_info(r: &mut Reader, path: &str, syms: &mut Vec<(String, String)>, rels: &mut Vec<Rel>) {
    let mut symbol = String::new();
    let mut display = String::new();
    let mut kind = 0f64;
    let mut enclosing = String::new();
    let mut doc = String::new();
    let mut prose = String::new();
    let mut related: Vec<(String, String)> = Vec::new();
    r.fields(|f, wt, s| match f {
        1 => symbol = clean(&s.string()),
        3 => {
            let text = s.string();
            if doc.is_empty() {
                doc = first_doc_line(&text);
            }
            let p = prose_of(&text);
            if !p.is_empty() {
                if prose.is_empty() {
                    prose = p;
                } else {
                    prose.push(' ');
                    prose.push_str(&p);
                }
            }
        }
        5 if wt == 0 => kind = s.varint(),
        6 => display = s.string().into_owned(),
        8 => enclosing = s.string().into_owned(),
        4 => {
            let mut other = String::new();
            let mut flags: Vec<&str> = Vec::new();
            s.fields(|rf, rwt, x| {
                if rf == 1 {
                    other = clean(&x.string());
                } else if rwt == 0 && (2..=5).contains(&rf) && x.varint() != 0.0 {
                    flags.push(["", "", "ref", "impl", "type", "def"][rf as usize]);
                }
            });
            if !other.is_empty() && !flags.is_empty() {
                related.push((other, flags.join(",")));
            }
        }
        _ => {}
    });
    if !symbol.is_empty() && !symbol.starts_with("local ") {
        let mut row = String::new();
        row.push_str(&symbol);
        row.push('\t');
        row.push_str(&display);
        row.push('\t');
        row.push_str(&num_string(kind));
        row.push('\t');
        row.push_str(&enclosing);
        row.push('\t');
        row.push_str(&slice16(&clean(&doc), 200));
        row.push('\t');
        row.push_str(&slice16(&clean(&prose), 600));
        if !path.is_empty() {
            for (other, flags) in related {
                rels.push([symbol.clone(), path.to_string(), other, flags]);
            }
        }
        syms.push((symbol, row));
    }
}

// ------------------------------------------------------- rustImplLinks

fn rust_impl_links(path: &str, pending: &[Pending], tab: &[SymEntry], rels: &mut Vec<Rel>) {
    let any = pending.iter().any(|p| p.roles & 1 != 0 && tab[p.sym as usize].flags & F_RA != 0);
    if !any {
        return;
    }
    let refs: Vec<usize> = (0..pending.len())
        .filter(|&i| pending[i].roles & 1 == 0 && tab[pending[i].sym as usize].flags & F_ENDS_HASH != 0)
        .collect();
    let mut seen: HashSet<(String, String)> = HashSet::new();
    for p in pending {
        let e = &tab[p.sym as usize];
        if p.roles & 1 == 0 || e.flags & F_RA == 0 {
            continue;
        }
        let Some((self_raw, trait_raw, member)) = rust_trait_impl(&e.s) else { continue };
        let self_n = bare_name(&self_raw);
        let trait_n = bare_name(&trait_raw);
        let line = p.range.first().copied().unwrap_or(f64::NAN);
        let nearest = |name: &str| -> Option<&str> {
            let mut best: Option<usize> = None;
            for &ri in &refs {
                let r = &pending[ri];
                let r0 = r.range.first().copied().unwrap_or(f64::NAN);
                if r0 > line {
                    continue;
                }
                let s = &tab[r.sym as usize].s;
                let tail = &s[s.rfind('/').map_or(0, |i| i + 1)..];
                let t2 = &tail[..tail.len() - 1];
                if bare_name(t2) != name {
                    continue;
                }
                let better = match best {
                    None => true,
                    Some(b) => r0 >= pending[b].range.first().copied().unwrap_or(f64::NAN),
                };
                if better {
                    best = Some(ri);
                }
            }
            best.map(|b| tab[pending[b].sym as usize].s.as_str())
        };
        let Some(trait_sym) = nearest(&trait_n) else { continue };
        if !member.is_empty() {
            rels.push([e.s.clone(), path.to_string(), format!("{trait_sym}{member}"), "ref,impl".to_string()]);
        }
        if let Some(self_sym) = nearest(&self_n) {
            let key = (self_sym.to_string(), trait_sym.to_string());
            if !seen.contains(&key) {
                seen.insert(key);
                rels.push([self_sym.to_string(), path.to_string(), trait_sym.to_string(), "impl".to_string()]);
            }
        }
    }
}

// ------------------------------------------------------------ one document

fn process_doc(buf: &[u8], start: usize, end: usize, path: String, fresh: bool) -> DocOut {
    let mut out = DocOut { path, fresh, ..Default::default() };
    let mut r = Reader { buf, pos: start, end };
    let mut infos: Vec<(usize, usize)> = Vec::new();
    let mut raw_pending: Vec<(Vec<f64>, Vec<f64>, &[u8], f64)> = Vec::new();
    r.fields(|df, _, d| {
        if df == 3 {
            infos.push((d.pos, d.end));
        } else if df == 2 {
            let mut range: Vec<f64> = Vec::new();
            let mut enclosing: Vec<f64> = Vec::new();
            let mut sym_raw: &[u8] = &[];
            let mut roles = 0f64;
            d.fields(|of, owt, o| {
                if of == 1 || of == 7 {
                    let into = if of == 1 { &mut range } else { &mut enclosing };
                    if owt == 2 {
                        while o.pos < o.end.min(o.buf.len()) {
                            into.push(o.varint());
                        }
                    } else {
                        into.push(o.varint());
                    }
                } else if (8..=11).contains(&of) {
                    if owt == 2 {
                        let into = if of == 8 || of == 9 { &mut range } else { &mut enclosing };
                        let np = if of == 8 || of == 10 { 3 } else { 4 };
                        let mut parts = [0f64; 4];
                        o.fields(|rf, rwt, x| {
                            if rwt == 0 && rf >= 1 && (rf as usize) <= np {
                                parts[rf as usize - 1] = x.varint();
                            }
                        });
                        into.clear();
                        into.extend_from_slice(&parts[..np]);
                    }
                } else if of == 2 {
                    sym_raw = o.raw();
                } else if of == 3 && owt == 0 {
                    roles = o.varint();
                }
            });
            raw_pending.push((range, enclosing, sym_raw, roles));
        }
    });
    for (s, e) in infos {
        let mut ir = Reader { buf, pos: s, end: e };
        symbol_info(&mut ir, &out.path, &mut out.syms, &mut out.rels);
    }
    let mut interner: FxMap<&[u8], u32> = FxMap::default();
    let mut pending: Vec<Pending> = Vec::with_capacity(raw_pending.len());
    for (range, enclosing, sym_raw, roles) in raw_pending {
        let id = match interner.get(sym_raw) {
            Some(&id) => id,
            None => {
                let id = out.tab.len() as u32;
                out.tab.push(make_entry(clean(&decode_utf8(sym_raw))));
                interner.insert(sym_raw, id);
                id
            }
        };
        pending.push(Pending { range, enclosing, sym: id, roles: to_int32_bits(roles) });
    }
    rust_impl_links(&out.path, &pending, &out.tab, &mut out.rels);
    if pending.iter().any(|p| out.tab[p.sym as usize].flags & F_RA != 0) {
        let mut taken: FxSet<u64> = FxSet::default();
        for p in &pending {
            if p.range.len() >= 2 {
                if let Some(k) = pos_key(p.range[0], p.range[1]) {
                    taken.insert(k);
                }
            }
        }
        out.taken = Some(taken);
    }
    out.rows.reserve(pending.len());
    for p in &pending {
        let e = &out.tab[p.sym as usize];
        if e.flags & (F_EMPTY | F_LOCAL) != 0 {
            continue;
        }
        let is_def = p.roles & 1 != 0;
        if is_def && e.flags & F_RA != 0 {
            out.defined.push(p.sym);
        }
        if is_def && p.enclosing.len() < 3 && e.flags & (F_CXX | F_DOTNET) != 0 && e.flags & F_CDEF_END != 0 {
            out.cdefs.push(CDef {
                sym: p.sym,
                line: p.range.first().copied(),
                col: p.range.get(1).copied(),
                cs: e.flags & F_DOTNET != 0,
            });
        }
        let role = if is_def {
            R_DEF
        } else if p.roles & 2 != 0 {
            R_IMP
        } else if e.flags & F_SWAN != 0 {
            R_NAME
        } else {
            R_REF
        };
        let (nums, n) = span_of(&p.range);
        out.rows.push(Row { sym: p.sym, n, role, nums });
        if p.enclosing.len() >= 3 {
            let (nums, _) = span_of(&p.enclosing);
            out.ext.push(ExtRow { sym: p.sym, nums });
        }
    }
    out
}

// ---------------------------------------------------------- source text

struct Lines {
    t: Vec<u16>,
    starts: Vec<usize>,
}
impl Lines {
    fn new(bytes: &[u8]) -> Lines {
        let s = String::from_utf8_lossy(bytes);
        let t: Vec<u16> = s.encode_utf16().collect();
        let mut starts = vec![0usize];
        for (i, &u) in t.iter().enumerate() {
            if u == 10 {
                starts.push(i + 1);
            }
        }
        Lines { t, starts }
    }
    fn count(&self) -> usize {
        self.starts.len()
    }
    fn line(&self, i: usize) -> &[u16] {
        let s = self.starts[i];
        let e = if i + 1 < self.starts.len() { self.starts[i + 1] - 1 } else { self.t.len() };
        &self.t[s..e]
    }
}

// sourceOf: the text a document's rows were indexed from.
fn source_of(path: &str, fresh: bool) -> Option<Lines> {
    let c = ctx();
    let kept = if !fresh { c.kept.get(path) } else { None };
    let p = match kept {
        Some(k) => k.clone(),
        None => posix_join(&[&c.repo_root, path]),
    };
    std::fs::read(p).ok().map(|b| Lines::new(&b))
}

fn sw(t: &[u16], i: usize, s: &str) -> bool {
    let b = s.as_bytes();
    t.len() >= i + b.len() && b.iter().enumerate().all(|(k, &c)| t[i + k] == c as u16)
}
fn skip_ws(t: &[u16], mut i: usize) -> usize {
    while i < t.len() && is_js_ws16(t[i]) {
        i += 1;
    }
    i
}
fn is_quote(u: u16) -> bool {
    u == b'"' as u16 || u == b'\'' as u16
}
// `["'][^"']+["']` starting just after the opening quote.
fn quoted_body(t: &[u16], s: usize) -> Option<usize> {
    let mut r = s;
    while r < t.len() && !is_quote(t[r]) {
        r += 1;
    }
    if r > s && r < t.len() {
        Some(r + 1)
    } else {
        None
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Form {
    Ts,
    Py,
    Rs,
    Java,
}
fn form_of(path: &str) -> Option<Form> {
    for pre in ["", "m", "c"] {
        for jt in ["j", "t"] {
            for x in ["", "x"] {
                if path.ends_with(&format!(".{pre}{jt}s{x}")) {
                    return Some(Form::Ts);
                }
            }
        }
    }
    if path.ends_with(".py") || path.ends_with(".pyi") {
        return Some(Form::Py);
    }
    if path.ends_with(".rs") {
        return Some(Form::Rs);
    }
    if path.ends_with(".java") || path.ends_with(".kt") || path.ends_with(".scala") {
        return Some(Form::Java);
    }
    None
}

// import\b[^;]*?(?:\bfrom\s*)?["'][^"']+["']
fn ts_alt_a(t: &[u16], q: usize) -> Option<usize> {
    let n = t.len();
    if q < n && is_word16(t[q]) {
        return None;
    }
    let mut k = q;
    loop {
        if sw(t, k, "from") && !is_word16(t[k - 1]) {
            let r = skip_ws(t, k + 4);
            if r < n && is_quote(t[r]) {
                if let Some(e) = quoted_body(t, r + 1) {
                    return Some(e);
                }
            }
        }
        if k < n && is_quote(t[k]) {
            if let Some(e) = quoted_body(t, k + 1) {
                return Some(e);
            }
        }
        if k >= n || t[k] == b';' as u16 {
            return None;
        }
        k += 1;
    }
}
// import\s+\w+\s*=\s*require\([^)]*\)
fn ts_alt_b(t: &[u16], q: usize) -> Option<usize> {
    let n = t.len();
    let r = skip_ws(t, q);
    if r == q {
        return None;
    }
    let mut w = r;
    while w < n && is_word16(t[w]) {
        w += 1;
    }
    if w == r {
        return None;
    }
    let mut p = skip_ws(t, w);
    if p >= n || t[p] != b'=' as u16 {
        return None;
    }
    p = skip_ws(t, p + 1);
    if !sw(t, p, "require(") {
        return None;
    }
    p += 8;
    while p < n && t[p] != b')' as u16 {
        p += 1;
    }
    if p < n {
        Some(p + 1)
    } else {
        None
    }
}
// export\s+(?:type\s+)?(?:\*|\{[^}]*\})\s*(?:as\s+\w+\s*)?from\s*["'][^"']+["']
fn ts_alt_c(t: &[u16], q: usize) -> Option<usize> {
    let n = t.len();
    let mut r = skip_ws(t, q);
    if r == q {
        return None;
    }
    if sw(t, r, "type") {
        let r2 = skip_ws(t, r + 4);
        if r2 == r + 4 {
            return None;
        }
        r = r2;
    }
    if r >= n {
        return None;
    }
    if t[r] == b'*' as u16 {
        r += 1;
    } else if t[r] == b'{' as u16 {
        let mut p = r + 1;
        while p < n && t[p] != b'}' as u16 {
            p += 1;
        }
        if p >= n {
            return None;
        }
        r = p + 1;
    } else {
        return None;
    }
    r = skip_ws(t, r);
    let tail = |from: usize| -> Option<usize> {
        // from\s*["'][^"']+["']
        if !sw(t, from, "from") {
            return None;
        }
        let p = skip_ws(t, from + 4);
        if p < n && is_quote(t[p]) {
            quoted_body(t, p + 1)
        } else {
            None
        }
    };
    if sw(t, r, "as") {
        let a = skip_ws(t, r + 2);
        if a == r + 2 {
            return None;
        }
        let mut b = a;
        while b < n && is_word16(t[b]) {
            b += 1;
        }
        let mut end = b;
        while end > a {
            let p = skip_ws(t, end);
            if let Some(e) = tail(p) {
                return Some(e);
            }
            end -= 1;
        }
        None
    } else {
        tail(r)
    }
}
fn ts_match(t: &[u16], p: usize) -> Option<usize> {
    if sw(t, p, "import") {
        if let Some(e) = ts_alt_a(t, p + 6) {
            return Some(e);
        }
        return ts_alt_b(t, p + 6);
    }
    if sw(t, p, "export") {
        return ts_alt_c(t, p + 6);
    }
    None
}
// from\s+[\w.]+\s+import\s+(?:\([^)]*\)|[^\n]*)  |  import\s+[^\n]*
fn py_tail(t: &[u16], p: usize) -> usize {
    let n = t.len();
    if p < n && t[p] == b'(' as u16 {
        let mut q = p + 1;
        while q < n && t[q] != b')' as u16 {
            q += 1;
        }
        if q < n {
            return q + 1;
        }
    }
    let mut q = p;
    while q < n && t[q] != 10 {
        q += 1;
    }
    q
}
fn py_match(t: &[u16], p: usize) -> Option<usize> {
    let n = t.len();
    if sw(t, p, "from") {
        let a = skip_ws(t, p + 4);
        if a == p + 4 {
            return None;
        }
        let mut b = a;
        while b < n && (is_word16(t[b]) || t[b] == b'.' as u16) {
            b += 1;
        }
        if b == a {
            return None;
        }
        let c = skip_ws(t, b);
        if c == b || !sw(t, c, "import") {
            return None;
        }
        let d = skip_ws(t, c + 6);
        if d == c + 6 {
            return None;
        }
        return Some(py_tail(t, d));
    }
    if sw(t, p, "import") {
        let d = skip_ws(t, p + 6);
        if d == p + 6 {
            return None;
        }
        let mut q = d;
        while q < n && t[q] != 10 {
            q += 1;
        }
        return Some(q);
    }
    None
}
// (?:pub(?:\([^)]*\))?\s+)?use\s+[^;]*;
fn rs_match(t: &[u16], p: usize) -> Option<usize> {
    let n = t.len();
    let mut q = p;
    if sw(t, q, "pub") {
        q += 3;
        if q < n && t[q] == b'(' as u16 {
            let mut x = q + 1;
            while x < n && t[x] != b')' as u16 {
                x += 1;
            }
            if x < n {
                q = x + 1;
            } else {
                return None;
            }
        }
        let r = skip_ws(t, q);
        if r == q {
            return None;
        }
        q = r;
    }
    if !sw(t, q, "use") {
        return None;
    }
    let r = skip_ws(t, q + 3);
    if r == q + 3 {
        return None;
    }
    let mut x = r;
    while x < n && t[x] != b';' as u16 {
        x += 1;
    }
    if x < n {
        Some(x + 1)
    } else {
        None
    }
}
// import\s+[^;\n]*;?
fn java_match(t: &[u16], p: usize) -> Option<usize> {
    let n = t.len();
    if !sw(t, p, "import") {
        return None;
    }
    let d = skip_ws(t, p + 6);
    if d == p + 6 {
        return None;
    }
    let mut x = d;
    while x < n && t[x] != b';' as u16 && t[x] != 10 {
        x += 1;
    }
    if x < n && t[x] == b';' as u16 {
        x += 1;
    }
    Some(x)
}
fn import_spans(t: &[u16], form: Form) -> Vec<(usize, usize)> {
    let n = t.len();
    let mut spans = Vec::new();
    let mut i = 0usize;
    while i <= n {
        if i == 0 || is_lt16(t[i - 1]) {
            let mut p = i;
            while p < n && (t[p] == b' ' as u16 || t[p] == b'\t' as u16) {
                p += 1;
            }
            let m = match form {
                Form::Ts => ts_match(t, p),
                Form::Py => py_match(t, p),
                Form::Rs => rs_match(t, p),
                Form::Java => java_match(t, p),
            };
            if let Some(e) = m {
                spans.push((i, e));
                i = e;
                continue;
            }
        }
        i += 1;
    }
    spans
}

// markImports for one document.
fn mark_imports(doc: &mut DocOut) {
    let Some(form) = form_of(&doc.path) else { return };
    if doc.rows.is_empty() {
        return;
    }
    let Some(lines) = source_of(&doc.path, doc.fresh) else { return };
    let t = &lines.t;
    let pos = |off: usize| -> (f64, f64) {
        let li = lines.starts.partition_point(|&s| s <= off) - 1;
        (li as f64, (off - lines.starts[li]) as f64)
    };
    let spans: Vec<((f64, f64), (f64, f64))> =
        import_spans(t, form).into_iter().map(|(s, e)| (pos(s), pos(e))).collect();
    if spans.is_empty() {
        return;
    }
    let lt = |a: (f64, f64), b: (f64, f64)| a.0 < b.0 || (a.0 == b.0 && a.1 < b.1);
    for row in doc.rows.iter_mut() {
        if row.role == R_REF && row.n == 4 {
            let p = (row.nums[0], row.nums[1]);
            // spans are sorted and disjoint: the last start <= p is the only candidate.
            let k = spans.partition_point(|s| !lt(p, s.0));
            if k > 0 && lt(p, spans[k - 1].1) {
                row.role = R_IMP;
            }
        }
    }
}

// ------------------------------------------------------------ rust macros

fn find_macro(line: &[u16], from: usize) -> Option<(usize, usize)> {
    let n = line.len();
    let lower = |u: u16| matches!(u, 0x61..=0x7a);
    let mut i = from;
    while i < n {
        if (i == 0 || !is_word16(line[i - 1])) && (lower(line[i]) || line[i] == b'_' as u16) {
            let mut j = i + 1;
            while j < n && (lower(line[j]) || matches!(line[j], 0x30..=0x39) || line[j] == b'_' as u16) {
                j += 1;
            }
            if j < n && line[j] == b'!' as u16 {
                let k = skip_ws(line, j + 1);
                if k < n && matches!(line[k], 0x28 | 0x5b | 0x7b) {
                    return Some((i, k + 1));
                }
            }
        }
        i += 1;
    }
    None
}

struct ByName {
    map: FxMap<String, Vec<String>>,
}
impl ByName {
    fn unique(&self, n: &str) -> Option<&String> {
        match self.map.get(n) {
            Some(v) if v.len() == 1 => Some(&v[0]),
            _ => None,
        }
    }
    fn member_of(&self, type_sym: &str, member: &str) -> Option<&String> {
        let module_len = type_sym.rfind('/').map_or(0, |i| i + 1);
        let module = &type_sym[..module_len];
        let type_name = bare_name(&type_sym[module_len..type_sym.len() - 1]);
        let p1 = format!("{module}impl#[{type_name}]");
        let p2 = format!("{module}impl#[`{type_name}<");
        for cand in self.map.get(member)? {
            if cand.starts_with(type_sym) || cand.starts_with(&p1) || cand.starts_with(&p2) {
                return Some(cand);
            }
        }
        None
    }
}

fn rust_macro_doc(doc: &mut DocOut, by: &ByName) {
    let Some(mut taken) = doc.taken.take() else { return };
    let Some(lines) = source_of(&doc.path, doc.fresh) else {
        doc.taken = Some(taken);
        return;
    };
    let nl = lines.count();
    let mut local: FxMap<String, u32> = FxMap::default();
    for ln in 0..nl {
        let line = lines.line(ln);
        let mut from = 0usize;
        while let Some((_mi, mend)) = find_macro(line, from) {
            let mut l = ln;
            let mut c = mend;
            let mut depth = 1i32;
            let mut in_str = false;
            let mut tokens: Vec<(usize, usize, usize)> = Vec::new();
            while l < nl && depth > 0 {
                let ll = lines.line(l);
                while c < ll.len() && depth > 0 {
                    let ch = ll[c];
                    if in_str {
                        if ch == b'\\' as u16 {
                            c += 1;
                        } else if ch == b'"' as u16 {
                            in_str = false;
                        }
                        c += 1;
                        continue;
                    }
                    if ch == b'"' as u16 {
                        in_str = true;
                        c += 1;
                        continue;
                    }
                    if matches!(ch, 0x28 | 0x5b | 0x7b) {
                        depth += 1;
                    } else if matches!(ch, 0x29 | 0x5d | 0x7d) {
                        depth -= 1;
                    }
                    let is_start = matches!(ch, 0x41..=0x5a | 0x61..=0x7a | 0x5f);
                    if is_start && (c == 0 || !is_word16(ll[c - 1])) {
                        let mut e = c + 1;
                        while e < ll.len() && is_word16(ll[e]) {
                            e += 1;
                        }
                        tokens.push((l, c, e - c));
                        c = e;
                        continue;
                    }
                    c += 1;
                }
                if depth > 0 {
                    l += 1;
                    c = 0;
                }
            }
            for (tl, tc, tlen) in tokens {
                let key = ((tl as u64) << 32) | tc as u64;
                if taken.contains(&key) {
                    continue;
                }
                let tline = lines.line(tl);
                let text: String = tline[tc..tc + tlen].iter().map(|&u| u as u8 as char).collect();
                // before = line.slice(0, c).trimEnd(); skip a field, method or path tail
                let mut be = tc;
                while be > 0 && is_js_ws16(tline[be - 1]) {
                    be -= 1;
                }
                if be >= 1 && tline[be - 1] == b'.' as u16 {
                    continue;
                }
                if be >= 2 && tline[be - 1] == b':' as u16 && tline[be - 2] == b':' as u16 {
                    continue;
                }
                let after = &tline[tc + tlen..];
                let mut sym: Option<&String> = None;
                let mut at_c = tc;
                let mut len = tlen;
                if text.as_bytes()[0].is_ascii_uppercase() {
                    let type_sym = by.unique(&text);
                    if let Some(ts) = type_sym {
                        // /^::([A-Za-z_][A-Za-z0-9_]*)/
                        let mut path2: Option<String> = None;
                        if after.len() >= 3
                            && after[0] == b':' as u16
                            && after[1] == b':' as u16
                            && matches!(after[2], 0x41..=0x5a | 0x61..=0x7a | 0x5f)
                        {
                            let mut e = 3;
                            while e < after.len() && is_word16(after[e]) {
                                e += 1;
                            }
                            path2 = Some(after[2..e].iter().map(|&u| u as u8 as char).collect());
                        }
                        if let Some(p2) = path2 {
                            if let Some(m) = by.member_of(ts, &p2) {
                                sym = Some(m);
                                at_c = tc + tlen + 2;
                                len = p2.len();
                            } else {
                                sym = Some(ts);
                            }
                        } else {
                            sym = Some(ts);
                        }
                    }
                } else {
                    let a = skip_ws(after, 0);
                    if a < after.len() && after[a] == b'(' as u16 {
                        if let Some(f) = by.unique(&text) {
                            if f.ends_with("().") {
                                sym = Some(f);
                            }
                        }
                    }
                }
                let Some(sym) = sym else { continue };
                let key2 = ((tl as u64) << 32) | at_c as u64;
                if taken.contains(&key2) {
                    continue;
                }
                taken.insert(key2);
                let id = match local.get(sym.as_str()) {
                    Some(&id) => id,
                    None => {
                        let id = doc.tab.len() as u32;
                        doc.tab.push(SymEntry { s: sym.clone(), flags: 0 });
                        local.insert(sym.clone(), id);
                        id
                    }
                };
                doc.rows.push(Row {
                    sym: id,
                    n: 4,
                    role: R_NAME,
                    nums: [tl as f64, at_c as f64, tl as f64, (at_c + len) as f64],
                });
            }
            from = if l == ln { c } else { line.len() };
        }
    }
    doc.taken = Some(taken);
}

// -------------------------------------------------------------- C bodies

fn starts_with_quotes(line: &[u16], c: usize, n: usize) -> bool {
    line.len() >= c + n && line[c..c + n].iter().all(|&u| u == b'"' as u16)
}
fn c_body(lines: &Lines, line0: usize, col0: usize, cs: bool) -> Option<(usize, usize)> {
    let mut l = line0;
    let mut c = col0;
    let mut depth: i64 = 0;
    let mut started = false;
    let mut done = false;
    let mut in_ch: u16 = 0;
    let mut in_len: usize = 0;
    let mut in_block = false;
    let mut verbatim = false;
    let mut arrow = false;
    let mut parens: i64 = 0;
    let q = b'"' as u16;
    'scan: while l < lines.count() {
        let line = lines.line(l);
        let n = line.len();
        while c < n {
            let ch = line[c];
            let two = |a: u8, b: u8| c + 1 < n && line[c] == a as u16 && line[c + 1] == b as u16;
            if in_block {
                if two(b'*', b'/') {
                    in_block = false;
                    c += 2;
                    continue;
                }
                c += 1;
                continue;
            }
            if in_len > 0 {
                if in_len > 1 {
                    if starts_with_quotes(line, c, in_len) {
                        c += in_len;
                        in_len = 0;
                    } else {
                        c += 1;
                    }
                    continue;
                }
                if verbatim {
                    if two(b'"', b'"') {
                        c += 2;
                        continue;
                    }
                    if ch == q {
                        in_len = 0;
                    }
                    c += 1;
                    continue;
                }
                if ch == b'\\' as u16 {
                    c += 2;
                    continue;
                }
                if ch == in_ch {
                    in_len = 0;
                }
                c += 1;
                continue;
            }
            if two(b'/', b'/') {
                break;
            }
            if two(b'/', b'*') {
                in_block = true;
                c += 2;
                continue;
            }
            let at = cs
                && ch == q
                && ((c >= 1 && line[c - 1] == b'@' as u16)
                    || (c >= 2 && line[c - 2] == b'@' as u16 && line[c - 1] == b'$' as u16));
            if cs && ch == q && !at && starts_with_quotes(line, c, 3) {
                let mut k = 3;
                while c + k < n && line[c + k] == q {
                    k += 1;
                }
                in_ch = q;
                in_len = k;
                c += k;
                continue;
            }
            if ch == q || ch == b'\'' as u16 {
                verbatim = at;
                in_ch = ch;
                in_len = 1;
                c += 1;
                continue;
            }
            if cs && !started && !arrow && parens == 0 && two(b'=', b'>') {
                arrow = true;
                c += 2;
                continue;
            }
            if cs && !started && !arrow {
                if ch == b'(' as u16 || ch == b'[' as u16 {
                    parens += 1;
                } else if ch == b')' as u16 || ch == b']' as u16 {
                    parens -= 1;
                }
            }
            if arrow {
                if matches!(ch, 0x28 | 0x7b | 0x5b) {
                    depth += 1;
                } else if matches!(ch, 0x29 | 0x7d | 0x5d) {
                    depth -= 1;
                } else if ch == b';' as u16 && depth == 0 {
                    done = true;
                    break 'scan;
                }
                c += 1;
                continue;
            }
            if !started && ch == b';' as u16 {
                break 'scan;
            }
            if ch == b'{' as u16 {
                depth += 1;
                started = true;
            } else if ch == b'}' as u16 && started {
                depth -= 1;
                if depth == 0 {
                    done = true;
                    break 'scan;
                }
            }
            c += 1;
        }
        l += 1;
        c = 0;
    }
    if done {
        Some((l, c))
    } else {
        None
    }
}

// ------------------------------------------------------------------ main

enum Item {
    Top(usize, usize),
    Doc { start: usize, end: usize, path: String },
}

fn scan_file(buf: &[u8], base: &str, explicit: bool, repo_abs: &str) -> Vec<Item> {
    let repo = &ctx().repo_root;
    let mut docbase = base.to_string();
    let mut items = Vec::new();
    let mut root = Reader::new(buf);
    root.fields(|f, _wt, r| {
        // Metadata.project_root: where document paths start.
        if f == 1 && !explicit && !repo.is_empty() {
            r.fields(|mf, _mwt, m| {
                if mf != 3 {
                    return;
                }
                let uri = m.string();
                if uri.starts_with("file://") {
                    let p = decode_uri_component(&uri[7..]).unwrap_or_else(|_| die("URIError: URI malformed"));
                    let rel = posix_relative(repo_abs, &p);
                    docbase = if !rel.is_empty() && !rel.starts_with("..") { rel } else { String::new() };
                }
            });
            return;
        }
        if f == 3 {
            items.push(Item::Top(r.pos, r.end));
            return;
        }
        if f != 2 {
            return;
        }
        let (s, e) = (r.pos, r.end);
        let mut path = String::new();
        r.fields(|df, _, d| {
            if df == 1 {
                let raw = d.string();
                path = clean_text(&if !docbase.is_empty() {
                    posix_normalize(&posix_join(&[&docbase, &raw]))
                } else {
                    raw.into_owned()
                });
            }
        });
        // A document for the run's target itself has an empty path.
        if path.is_empty() && !docbase.is_empty() {
            path = posix_normalize(&docbase);
        }
        if ctx().ignored.iter().any(|dir| path.starts_with(dir.as_str())) {
            return;
        }
        items.push(Item::Doc { start: s, end: e, path });
    });
    items
}

enum Work {
    Top { file: usize, start: usize, end: usize },
    Doc { file: usize, start: usize, end: usize, path: String, fresh: bool },
}
enum WorkOut {
    Top(Vec<(String, String)>),
    Doc(Box<DocOut>),
}
struct CExt {
    sym: String,
    path: String,
    line: f64,
    l: usize,
    c: usize,
}

fn read_lines_file(f: &str) -> Vec<String> {
    let b = std::fs::read(f).unwrap_or_else(|e| die(&format!("Error: {f}: {e}")));
    String::from_utf8_lossy(&b).split('\n').filter(|l| !l.is_empty()).map(String::from).collect()
}

fn main() {
    let mut argv: Vec<String> = std::env::args().skip(1).collect();
    let mut repo_root = String::new();
    let mut abs_prefix = String::new();
    let mut fresh: Option<HashSet<String>> = None;
    let mut kept: HashMap<String, String> = HashMap::new();
    let mut ignored: Vec<String> = Vec::new();
    while !argv.is_empty() && matches!(argv[0].as_str(), "--fresh" | "--texts" | "--root" | "--ignored") {
        let flag = argv.remove(0);
        if argv.is_empty() {
            die(&format!("Error: {flag} needs a value"));
        }
        let value = argv.remove(0);
        if flag == "--fresh" {
            fresh = Some(read_lines_file(&value).into_iter().collect());
        } else if flag == "--ignored" {
            ignored = read_lines_file(&value).into_iter().filter(|l| !l.is_empty()).map(|l| format!("{l}/")).collect();
        } else if flag == "--texts" {
            for l in read_lines_file(&value) {
                if let Some(t) = l.find('\t') {
                    if t > 0 {
                        kept.insert(l[..t].to_string(), l[t + 1..].to_string());
                    }
                }
            }
        } else {
            repo_root = value.clone();
            let segs: Vec<String> = posix_resolve(&value)
                .split('/')
                .filter(|s| !s.is_empty())
                .map(|g| {
                    if g.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '$' | '+' | '-')) {
                        g.to_string()
                    } else {
                        format!("`{}`", g.replace('`', "``"))
                    }
                })
                .collect();
            abs_prefix = format!(" {}/", segs.join("/"));
        }
    }
    if argv.len() < 2 {
        eprintln!("usage: swan-flatten [--fresh <list>] [--texts <tsv>] [--root <repo>] <index.scip> <out-dir> [more.scip ...]");
        std::process::exit(2);
    }
    let out_dir = argv[1].clone();
    let mut specs: Vec<String> = vec![argv[0].clone()];
    specs.extend(argv[2..].iter().cloned());
    let _ = CTX.set(Ctx { repo_root: repo_root.clone(), abs_prefix, fresh, kept, ignored });

    let t0 = std::time::Instant::now();
    // "index.scip=dir" says its document paths are relative to dir.
    let parsed: Vec<(String, String)> = specs
        .iter()
        .map(|spec| match spec.rfind('=') {
            Some(eq) if eq > 0 => (spec[..eq].to_string(), spec[eq + 1..].to_string()),
            _ => (spec.clone(), String::new()),
        })
        .collect();
    let bufs: Vec<Vec<u8>> = parsed
        .par_iter()
        .map(|(f, _)| std::fs::read(f).unwrap_or_else(|e| die(&format!("Error: {f}: {e}"))))
        .collect();
    let repo_abs = if repo_root.is_empty() { String::new() } else { posix_resolve(&repo_root) };
    let all_items: Vec<Vec<Item>> = bufs
        .par_iter()
        .zip(parsed.par_iter())
        .map(|(b, (_, base))| scan_file(b, base, !base.is_empty(), &repo_abs))
        .collect();

    // Documents seen first stand; repeats are dropped (in file order).
    let mut seen: FxSet<String> = FxSet::default();
    let mut work: Vec<Work> = Vec::new();
    let (mut docs, mut dup_docs) = (0usize, 0usize);
    for (fi, items) in all_items.into_iter().enumerate() {
        let is_fresh = ctx().fresh.as_ref().map_or(true, |s| s.contains(&parsed[fi].0));
        for it in items {
            match it {
                Item::Top(s, e) => work.push(Work::Top { file: fi, start: s, end: e }),
                Item::Doc { start, end, path } => {
                    if seen.contains(&path) {
                        dup_docs += 1;
                        continue;
                    }
                    // MSBuild's obj/ folders hold generated code.
                    if path.starts_with("obj/") || path.contains("/obj/") {
                        continue;
                    }
                    seen.insert(path.clone());
                    docs += 1;
                    work.push(Work::Doc { file: fi, start, end, path, fresh: is_fresh });
                }
            }
        }
    }
    drop(seen);

    let outs: Vec<WorkOut> = work
        .into_par_iter()
        .map(|w| match w {
            Work::Top { file, start, end } => {
                let mut r = Reader { buf: &bufs[file], pos: start, end };
                let mut syms = Vec::new();
                let mut rels = Vec::new();
                symbol_info(&mut r, "", &mut syms, &mut rels);
                WorkOut::Top(syms)
            }
            Work::Doc { file, start, end, path, fresh } => {
                WorkOut::Doc(Box::new(process_doc(&bufs[file], start, end, path, fresh)))
            }
        })
        .collect();
    drop(bufs);

    // Merge in the original order.
    let mut sym_idx: FxMap<String, usize> = FxMap::default();
    let mut sym_rows: Vec<String> = Vec::new();
    let mut rel: Vec<Rel> = Vec::new();
    let mut defined_order: Vec<String> = Vec::new();
    let mut defined_set: FxSet<String> = FxSet::default();
    let mut doc_list: Vec<DocOut> = Vec::new();
    let mut apply = |v: Vec<(String, String)>| {
        for (k, row) in v {
            match sym_idx.get(&k) {
                Some(&i) => sym_rows[i] = row,
                None => {
                    sym_idx.insert(k, sym_rows.len());
                    sym_rows.push(row);
                }
            }
        }
    };
    for o in outs {
        match o {
            WorkOut::Top(v) => apply(v),
            WorkOut::Doc(mut d) => {
                apply(std::mem::take(&mut d.syms));
                rel.append(&mut d.rels);
                for &id in &d.defined {
                    let s = &d.tab[id as usize].s;
                    if !defined_set.contains(s) {
                        defined_set.insert(s.clone());
                        defined_order.push(s.clone());
                    }
                }
                d.defined = Vec::new();
                doc_list.push(*d);
            }
        }
    }
    drop(defined_set);
    drop(sym_idx);

    let have_root = !repo_root.is_empty();
    if have_root {
        // rustMacroUses
        let mut by = ByName { map: FxMap::default() };
        for sym in &defined_order {
            if !sym.starts_with("rust-analyzer ") || sym.ends_with(')') || sym.ends_with(']') {
                continue;
            }
            let n = last_name(sym);
            if n.is_empty() {
                continue;
            }
            by.map.entry(n).or_default().push(sym.clone());
        }
        doc_list.par_iter_mut().for_each(|d| rust_macro_doc(d, &by));
    }

    // cBodies
    let mut cext: Vec<CExt> = Vec::new();
    if have_root {
        let mut jobs: Vec<(usize, usize)> = Vec::new();
        let mut doc_ids: Vec<usize> = Vec::new();
        for (di, d) in doc_list.iter().enumerate() {
            if !d.cdefs.is_empty() {
                doc_ids.push(di);
                for ci in 0..d.cdefs.len() {
                    jobs.push((di, ci));
                }
            }
        }
        let loaded: Vec<(usize, Option<Lines>)> = doc_ids
            .par_iter()
            .map(|&di| (di, source_of(&doc_list[di].path, doc_list[di].fresh)))
            .collect();
        let text_of: FxMap<usize, &Lines> =
            loaded.iter().filter_map(|(di, l)| l.as_ref().map(|l| (*di, l))).collect();
        let res: Vec<Option<CExt>> = jobs
            .par_iter()
            .map(|&(di, ci)| {
                let d = &doc_list[di];
                let cd = &d.cdefs[ci];
                let lines = text_of.get(&di)?;
                let line = cd.line?;
                if !(line >= 0.0) || line.fract() != 0.0 {
                    return None;
                }
                let l0 = line as usize;
                if l0 >= lines.count() {
                    return None;
                }
                let col0 = match cd.col {
                    Some(c) if c >= 0.0 && c.fract() == 0.0 && c < 1e15 => c as usize,
                    _ => usize::MAX,
                };
                let (l, c) = c_body(lines, l0, col0, cd.cs)?;
                Some(CExt { sym: d.tab[cd.sym as usize].s.clone(), path: d.path.clone(), line, l, c: c + 1 })
            })
            .collect();
        cext = res.into_iter().flatten().collect();
    }

    if have_root {
        doc_list.par_iter_mut().for_each(mark_imports);
    }

    // dropReverseImplLinks
    {
        let owner = |s: &str| -> String { s[..s.rfind('#').map_or(0, |i| i + 1)].to_string() };
        let keep: Vec<bool> = {
            let mut has: FxSet<(&str, &str, bool)> = FxSet::default();
            let mut type_impl: FxSet<(&str, &str)> = FxSet::default();
            for e in &rel {
                has.insert((e[0].as_str(), e[2].as_str(), e[3].contains("impl")));
                if e[0].ends_with('#') && e[3].contains("impl") {
                    type_impl.insert((e[0].as_str(), e[2].as_str()));
                }
            }
            rel.iter()
                .map(|e| {
                    let (a, b, f) = (e[0].as_str(), e[2].as_str(), e[3].as_str());
                    if !f.contains("impl") || a.ends_with('#') || !has.contains(&(b, a, true)) {
                        return true;
                    }
                    let (ob, oa) = (owner(b), owner(a));
                    !type_impl.contains(&(ob.as_str(), oa.as_str()))
                })
                .collect()
        };
        let mut it = keep.iter();
        rel.retain(|_| *it.next().unwrap());
    }

    // Output.
    std::fs::create_dir_all(&out_dir).unwrap_or_else(|e| die(&format!("Error: {out_dir}: {e}")));
    let occ_chunks: Vec<Vec<u8>> = doc_list
        .par_iter()
        .map(|d| {
            let mut o = Vec::with_capacity(d.rows.len() * 96);
            for r in &d.rows {
                o.extend_from_slice(d.tab[r.sym as usize].s.as_bytes());
                o.push(b'\t');
                o.extend_from_slice(d.path.as_bytes());
                for k in 0..r.n as usize {
                    o.push(b'\t');
                    push_num(&mut o, r.nums[k]);
                }
                o.push(b'\t');
                o.extend_from_slice(ROLE_STR[r.role as usize].as_bytes());
                o.push(b'\n');
            }
            o
        })
        .collect();
    let ext_chunks: Vec<Vec<u8>> = doc_list
        .par_iter()
        .map(|d| {
            let mut o = Vec::with_capacity(d.ext.len() * 96);
            for r in &d.ext {
                o.extend_from_slice(d.tab[r.sym as usize].s.as_bytes());
                o.push(b'\t');
                o.extend_from_slice(d.path.as_bytes());
                for k in 0..4 {
                    o.push(b'\t');
                    push_num(&mut o, r.nums[k]);
                }
                o.push(b'\n');
            }
            o
        })
        .collect();
    let n_occ: usize = doc_list.iter().map(|d| d.rows.len()).sum();
    let n_ext: usize = doc_list.iter().map(|d| d.ext.len()).sum::<usize>() + cext.len();
    let n_syms = sym_rows.len();
    let n_rel = rel.len();
    let write_file = |name: &str, f: &dyn Fn(&mut std::io::BufWriter<std::fs::File>) -> std::io::Result<()>| {
        let p = std::path::Path::new(&out_dir).join(name);
        let file = std::fs::File::create(&p).unwrap_or_else(|e| die(&format!("Error: {}: {e}", p.display())));
        let mut w = std::io::BufWriter::with_capacity(1 << 20, file);
        f(&mut w).and_then(|_| w.flush()).unwrap_or_else(|e| die(&format!("Error: {}: {e}", p.display())));
    };
    std::thread::scope(|s| {
        s.spawn(|| {
            write_file("occurrences.tsv", &|w| {
                if n_occ == 0 {
                    w.write_all(b"\n")?;
                }
                for c in &occ_chunks {
                    w.write_all(c)?;
                }
                Ok(())
            })
        });
        s.spawn(|| {
            write_file("symbols.tsv", &|w| {
                if sym_rows.is_empty() {
                    w.write_all(b"\n")?;
                }
                for r in &sym_rows {
                    w.write_all(r.as_bytes())?;
                    w.write_all(b"\n")?;
                }
                Ok(())
            })
        });
        s.spawn(|| {
            write_file("extents.tsv", &|w| {
                if n_ext == 0 {
                    w.write_all(b"\n")?;
                }
                for c in &ext_chunks {
                    w.write_all(c)?;
                }
                let mut o = Vec::new();
                for x in &cext {
                    o.clear();
                    o.extend_from_slice(x.sym.as_bytes());
                    o.push(b'\t');
                    o.extend_from_slice(x.path.as_bytes());
                    o.push(b'\t');
                    push_num(&mut o, x.line);
                    o.extend_from_slice(b"\t0\t");
                    push_u64(&mut o, x.l as u64);
                    o.push(b'\t');
                    push_u64(&mut o, x.c as u64);
                    o.push(b'\n');
                    w.write_all(&o)?;
                }
                Ok(())
            })
        });
        s.spawn(|| {
            write_file("relationships.tsv", &|w| {
                if rel.is_empty() {
                    w.write_all(b"\n")?;
                }
                for e in &rel {
                    w.write_all(e[0].as_bytes())?;
                    w.write_all(b"\t")?;
                    w.write_all(e[1].as_bytes())?;
                    w.write_all(b"\t")?;
                    w.write_all(e[2].as_bytes())?;
                    w.write_all(b"\t")?;
                    w.write_all(e[3].as_bytes())?;
                    w.write_all(b"\n")?;
                }
                Ok(())
            })
        });
        s.spawn(|| {
            write_file("documents.tsv", &|w| {
                for d in &doc_list {
                    w.write_all(d.path.as_bytes())?;
                    w.write_all(if d.fresh { b"\t1\n" } else { b"\t0\n" })?;
                }
                Ok(())
            })
        });
    });
    eprintln!(
        "scip-flatten: {} documents{}, {} occurrences, {} symbols, {} extents, {} relationships in {} ms",
        docs,
        if dup_docs > 0 { format!(" ({dup_docs} repeats dropped)") } else { String::new() },
        n_occ,
        n_syms,
        n_ext,
        n_rel,
        t0.elapsed().as_millis()
    );
}
