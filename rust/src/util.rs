// Byte-string helpers with the meanings Goose's builtins have (its
// stdlib/std.goose, json.goose and dictionary.goose), which the code carried
// over from src/*.goose leans on: text is bytes, `find` gives -1 for "not
// there", `split` keeps empty parts.

use std::io::Write;

pub fn find(hay: &[u8], needle: &[u8]) -> i64 {
    if needle.is_empty() {
        return 0;
    }
    if needle.len() > hay.len() {
        return -1;
    }
    match hay.windows(needle.len()).position(|w| w == needle) {
        Some(i) => i as i64,
        None => -1,
    }
}

pub fn rfind(hay: &[u8], needle: &[u8]) -> i64 {
    if needle.is_empty() {
        return hay.len() as i64;
    }
    if needle.len() > hay.len() {
        return -1;
    }
    match hay.windows(needle.len()).rposition(|w| w == needle) {
        Some(i) => i as i64,
        None => -1,
    }
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n' || c == b'\r'
}

/// ASCII whitespace trimmed: a sub-slice of s.
pub fn trim(s: &[u8]) -> &[u8] {
    let mut a = 0;
    let mut b = s.len();
    while a < b && is_space(s[a]) {
        a += 1;
    }
    while b > a && is_space(s[b - 1]) {
        b -= 1;
    }
    &s[a..b]
}

pub fn starts_with(s: &[u8], p: &[u8]) -> bool {
    s.starts_with(p)
}

pub fn ends_with(s: &[u8], p: &[u8]) -> bool {
    s.ends_with(p)
}

/// The parts of s between each sep; empty parts are kept ("a\n" gives "a" and "").
pub fn split(s: &[u8], sep: u8) -> Vec<&[u8]> {
    s.split(|&c| c == sep).collect()
}

/// The rows of tab-separated text: each line (without its '\n'), its first
/// eight fields and how many fields it has. One vectorized pass finds every
/// tab and line end. The text after the last line end is a row too, as in
/// `split`, and so is an empty line.
pub fn tsv_rows(text: &[u8]) -> TsvRows<'_> {
    TsvRows { text, at: memchr::memchr2_iter(b'\t', b'\n', text), start: 0, done: false }
}

pub struct TsvRows<'a> {
    text: &'a [u8],
    at: memchr::Memchr2<'a>,
    start: usize,
    done: bool,
}

impl<'a> Iterator for TsvRows<'a> {
    type Item = (&'a [u8], [&'a [u8]; 8], usize);
    fn next(&mut self) -> Option<Self::Item> {
        if self.done {
            return None;
        }
        let mut f: [&[u8]; 8] = [&[]; 8];
        let mut n = 0;
        let line_start = self.start;
        let mut field_start = self.start;
        loop {
            match self.at.next() {
                Some(i) => {
                    if n < 8 {
                        f[n] = &self.text[field_start..i];
                    }
                    n += 1;
                    field_start = i + 1;
                    if self.text[i] == b'\n' {
                        self.start = i + 1;
                        return Some((&self.text[line_start..i], f, n));
                    }
                }
                None => {
                    self.done = true;
                    if n < 8 {
                        f[n] = &self.text[field_start..];
                    }
                    return Some((&self.text[line_start..], f, n + 1));
                }
            }
        }
    }
}

/// An optionally signed whole-string integer; None on anything else,
/// including a value outside i64.
pub fn parse_int(s: &[u8]) -> Option<i64> {
    let mut i = 0;
    let mut neg = false;
    if !s.is_empty() && (s[0] == b'-' || s[0] == b'+') {
        neg = s[0] == b'-';
        i = 1;
    }
    if i >= s.len() {
        return None;
    }
    // The magnitude accumulates as a negative number: -2^63 has no positive
    // counterpart, while every other magnitude has a negative one.
    let mut v: i64 = 0;
    while i < s.len() {
        let c = s[i];
        if !c.is_ascii_digit() {
            return None;
        }
        let d = (c - b'0') as i64;
        if v < (i64::MIN + d) / 10 {
            return None;
        }
        v = v * 10 - d;
        i += 1;
    }
    if !neg {
        if v == i64::MIN {
            return None;
        }
        v = -v;
    }
    Some(v)
}

pub fn push_int(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(v.to_string().as_bytes());
}

/// `text` with every `from` replaced by `to`, appended to out.
pub fn push_replaced(out: &mut Vec<u8>, text: &[u8], from: &[u8], to: &[u8]) {
    let mut rest = text;
    loop {
        let at = find(rest, from);
        if at < 0 {
            out.extend_from_slice(rest);
            return;
        }
        out.extend_from_slice(&rest[..at as usize]);
        out.extend_from_slice(to);
        rest = &rest[at as usize + from.len()..];
    }
}

/// Whether one of the lines of `lines` is exactly s.
pub fn contains_line(lines: &[u8], s: &[u8]) -> bool {
    lines.split(|&c| c == b'\n').any(|l| l == s)
}

/// Says what is wrong and ends the run: Goose's abort(), without its
/// "goose runtime error: " before the message and its source line after.
pub fn die(msg: &[u8]) -> ! {
    let mut m = msg.to_vec();
    m.push(b'\n');
    let _ = std::io::stderr().write_all(&m);
    std::process::exit(1);
}

/// Goose's print(): the text and a line end, on standard output.
pub fn print(text: &[u8]) {
    let mut m = text.to_vec();
    m.push(b'\n');
    let out = std::io::stdout();
    let mut out = out.lock();
    let _ = out.write_all(&m);
    let _ = out.flush();
}

// ---- JSON writing (stdlib/json.goose) ----

/// s as a JSON string: quoted, with '"', '\' and the control characters escaped.
pub fn json_string(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    let mut start = 0;
    for (i, &c) in s.iter().enumerate() {
        if c >= 0x20 && c != b'"' && c != b'\\' {
            continue;
        }
        out.extend_from_slice(&s[start..i]);
        start = i + 1;
        match c {
            b'"' | b'\\' => {
                out.push(b'\\');
                out.push(c);
            }
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            8 => out.extend_from_slice(b"\\b"),
            12 => out.extend_from_slice(b"\\f"),
            _ => {
                out.extend_from_slice(b"\\u00");
                out.push(b"0123456789abcdef"[(c >> 4) as usize]);
                out.push(b"0123456789abcdef"[(c & 15) as usize]);
            }
        }
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

/// An object key and its colon.
pub fn json_key(out: &mut Vec<u8>, key: &[u8]) {
    json_string(out, key);
    out.push(b':');
}

// ---- hashing (stdlib/std.goose) ----
// A hash of a byte string: Goose's `hash`, step for step. A file's
// fingerprint in the map (files.hash) is made of these numbers, so a map
// written by the Goose program is not redone because the program changed
// language. Not to be changed without rebuilding every map.
const K1: u64 = 11400714819323198485;
const K2: u64 = 15485907386658061715;

fn le64(s: &[u8], i: usize) -> u64 {
    let mut b = [0u8; 8];
    b.copy_from_slice(&s[i..i + 8]);
    u64::from_le_bytes(b)
}

fn le32(s: &[u8], i: usize) -> u64 {
    let mut b = [0u8; 4];
    b.copy_from_slice(&s[i..i + 4]);
    u32::from_le_bytes(b) as u64
}

pub fn hash(s: &[u8]) -> u64 {
    let n = s.len();
    if n > 24 {
        return hash_lanes(s);
    }
    let mut h = (n as u64).wrapping_mul(K1);
    let mut w: u64 = 0;
    if n > 8 {
        let mut i = 0;
        while i < n - 8 {
            h = (h ^ le64(s, i)).wrapping_mul(K1);
            h = (h << 29) | (h >> 35);
            i += 8;
        }
        w = le64(s, n - 8);
    } else if n >= 4 {
        w = le32(s, 0) | le32(s, n - 4) << 32;
    } else if n > 0 {
        w = s[0] as u64 | (s[n >> 1] as u64) << 8 | (s[n - 1] as u64) << 16;
    }
    h = (h ^ w).wrapping_mul(K1);
    h = (h ^ (h >> 32)).wrapping_mul(K2);
    h ^ (h >> 32)
}

fn hash_lanes(s: &[u8]) -> u64 {
    let n = s.len();
    let mut h = (n as u64).wrapping_mul(K1);
    let mut g = h ^ 0x9E3779B97F4A7C15;
    let mut i = 0;
    while i < n - 24 {
        h = (h ^ le64(s, i)).wrapping_mul(K1);
        h = (h << 29) | (h >> 35);
        g = (g ^ le64(s, i + 8)).wrapping_mul(K1);
        g = (g << 29) | (g >> 35);
        i += 16;
    }
    h ^= (g << 31) | (g >> 33);
    while i < n - 8 {
        h = (h ^ le64(s, i)).wrapping_mul(K1);
        h = (h << 29) | (h >> 35);
        i += 8;
    }
    h = (h ^ le64(s, n - 8)).wrapping_mul(K1);
    h = (h ^ (h >> 32)).wrapping_mul(K2);
    h ^ (h >> 32)
}

pub fn hash_combine(seed: u64, h: u64) -> u64 {
    seed ^ (h.wrapping_add(K1).wrapping_add(seed << 6).wrapping_add(seed >> 2))
}

// Rust's own hash tables, hashing text with the hash above in place of the
// standard one (which is made to resist chosen keys, and is slower): for
// tables whose order nothing depends on.
#[derive(Default)]
pub struct TextHasher(u64);

impl std::hash::Hasher for TextHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        self.0 = hash_combine(self.0, hash(bytes));
    }
    fn write_usize(&mut self, _: usize) {} // a slice's length: already in its hash
}

pub type TextMap<K, V> = std::collections::HashMap<K, V, std::hash::BuildHasherDefault<TextHasher>>;
pub type TextSet<K> = std::collections::HashSet<K, std::hash::BuildHasherDefault<TextHasher>>;

// ---- dictionary (stdlib/dictionary.goose) ----
// Goose's dictionary keyed by text, slot for slot: open addressing with
// linear probing over a power-of-two slot array, doubled in place at 2/3
// load. `each` walks the slots, so its order is the Goose program's order,
// and rows written while walking one (the map's `files` table) land in the
// same order in both programs.

#[derive(Clone, Copy)]
struct Slot<'a, V> {
    key: &'a [u8],
    val: V,
    tag: u32, // 0 unused, else the low 31 bits of the key's hash with bit 31 set
}

pub struct Dict<'a, V: Copy + Default> {
    pub count: i64,
    slots: Vec<Slot<'a, V>>,
}

fn dict_tag(h: u64) -> u32 {
    (h as u32) | 2147483648
}

impl<'a, V: Copy + Default> Dict<'a, V> {
    pub fn new() -> Self {
        Dict { count: 0, slots: Vec::new() }
    }

    // The slot holding key, or else the unused slot where it goes.
    fn slot(&self, key: &[u8], h: u64) -> usize {
        let tag = dict_tag(h);
        let mask = self.slots.len() - 1;
        let mut i = (h as usize) & mask;
        loop {
            let t = self.slots[i].tag;
            if t == tag {
                if self.slots[i].key == key {
                    return i;
                }
            } else if t == 0 {
                return i;
            }
            i = (i + 1) & mask;
        }
    }

    fn room(&mut self) {
        if self.slots.is_empty() {
            self.grow(8);
        } else if (self.count + 1) * 3 > self.slots.len() as i64 * 2 {
            self.grow(self.slots.len() * 2);
        }
    }

    // Every entry is re-placed by a walk over the old slots in cyclic order
    // from just after an unused one.
    fn grow(&mut self, cap: usize) {
        let old = self.slots.len();
        self.slots.resize(cap, Slot { key: &[], val: V::default(), tag: 0 });
        if self.count == 0 {
            return;
        }
        let mask = cap - 1;
        let mut s = 0;
        while self.slots[s].tag != 0 {
            s += 1;
        }
        for k in 1..old {
            let mut p = s + k;
            if p >= old {
                p -= old;
            }
            let t = self.slots[p].tag;
            if t != 0 {
                let mut q = (t as usize) & mask;
                if mask >= 2147483648 {
                    q = (hash(self.slots[p].key) as usize) & mask;
                }
                let e = self.slots[p];
                self.slots[p].tag = 0;
                while self.slots[q].tag != 0 {
                    q = (q + 1) & mask;
                }
                self.slots[q] = e;
            }
        }
    }

    /// The value for key, inserted as v0 first if absent.
    pub fn entry(&mut self, key: &'a [u8], v0: V) -> &mut V {
        self.room();
        let h = hash(key);
        let i = self.slot(key, h);
        if self.slots[i].tag == 0 {
            self.slots[i] = Slot { key, val: v0, tag: dict_tag(h) };
            self.count += 1;
        }
        &mut self.slots[i].val
    }

    /// Every entry, in slot order.
    pub fn each(&self) -> impl Iterator<Item = (&'a [u8], V)> + '_ {
        self.slots.iter().filter(|s| s.tag != 0).map(|s| (s.key, s.val))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // What Goose's own `hash` gives for these (printed by a Goose program,
    // goose v2026.3): every branch of it, by length.
    #[test]
    fn hash_is_gooses_hash() {
        let want: [(usize, u64); 15] = [
            (0, 0),
            (1, 874251148392455296),
            (2, 7959004758223221308),
            (3, 16215211943321213931),
            (4, 14487226252335792074),
            (7, 12907706472906408456),
            (8, 4445469909192656180),
            (9, 15692679031000609385),
            (16, 14321181025998159423),
            (17, 7037860686989985198),
            (24, 16107364775720477008),
            (25, 9723631951205810525),
            (40, 16184706048744675262),
            (41, 11678578902861428149),
            (100, 4921713829712216036),
        ];
        for (n, h) in want {
            let text: Vec<u8> = (0..n).map(|i| b'a' + ((i * 7) % 26) as u8).collect();
            assert_eq!(hash(&text), h, "length {}", n);
        }
    }

    #[test]
    fn helpers_have_the_goose_meanings() {
        assert_eq!(find(b"abc", b"c"), 2);
        assert_eq!(find(b"abc", b"x"), -1);
        assert_eq!(rfind(b"a/b/c", b"/"), 3);
        assert_eq!(split(b"a\n", b'\n'), vec![&b"a"[..], &b""[..]]);
        assert_eq!(parse_int(b"-12"), Some(-12));
        assert_eq!(parse_int(b"+7"), Some(7));
        assert_eq!(parse_int(b"12a"), None);
        assert_eq!(parse_int(b""), None);
        assert_eq!(parse_int(b"-9223372036854775808"), Some(i64::MIN));
        assert_eq!(parse_int(b"9223372036854775808"), None);
        assert_eq!(trim(b" \t a b\n"), b"a b");
        let mut o = Vec::new();
        json_string(&mut o, b"a\"b\\c\n\x01");
        assert_eq!(o, b"\"a\\\"b\\\\c\\n\\u0001\"");
        let mut r = Vec::new();
        push_replaced(&mut r, b"in (#IDS#) or (#IDS#)", b"#IDS#", b"1,2");
        assert_eq!(r, b"in (1,2) or (1,2)");
    }

    #[test]
    fn dict_keeps_every_key_through_growth() {
        let keys: Vec<Vec<u8>> = (0..1000).map(|i| format!("src/file-{i}.rs").into_bytes()).collect();
        let mut d: Dict<i64> = Dict::new();
        for (i, k) in keys.iter().enumerate() {
            *d.entry(k, 0) += i as i64 + 1;
        }
        assert_eq!(d.count, 1000);
        let got: std::collections::HashMap<&[u8], i64> = d.each().collect();
        assert_eq!(got.len(), 1000);
        for (i, k) in keys.iter().enumerate() {
            assert_eq!(got.get(&k[..]), Some(&(i as i64 + 1)));
        }
        // A key seen again keeps its value and adds no entry.
        *d.entry(&keys[7], 0) += 100;
        assert_eq!(d.count, 1000);
        assert_eq!(d.each().find(|(k, _)| *k == &keys[7][..]).map(|(_, v)| v), Some(108));
    }

    // tsv_rows gives what `split` on '\n' and then on '\t' gives: empty
    // lines and the text after the last line end included.
    #[test]
    fn tsv_rows_are_the_split_rows() {
        let texts: [&[u8]; 7] = [b"", b"a", b"a\n", b"a\tb\n\nc\t\td", b"\t\n\t", b"1\t2\t3\t4\t5\t6\t7\t8\t9\t10\nx", b"\n\n"];
        for text in texts {
            let want: Vec<(&[u8], Vec<&[u8]>)> = split(text, b'\n').into_iter().map(|l| (l, split(l, b'\t'))).collect();
            let got: Vec<(&[u8], [&[u8]; 8], usize)> = tsv_rows(text).collect();
            assert_eq!(got.len(), want.len(), "{:?}", text);
            for ((line, f, n), (wline, wf)) in got.iter().zip(&want) {
                assert_eq!(line, wline);
                assert_eq!(*n, wf.len());
                for k in 0..8 {
                    assert_eq!(f[k], if k < wf.len() { wf[k] } else { &b""[..] });
                }
            }
        }
    }
}
