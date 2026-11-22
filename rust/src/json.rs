// Reading JSON. Goose's stdlib/json.goose, the part Swan uses: `parse`,
// `member`, `each` and the three `as_` readers. What is JSON and what is
// not is decided as there, byte for byte: a string may hold any byte from
// 0x20 up, an escape must be one of \" \\ \/ \b \f \n \r \t \uXXXX, a
// number is -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?, and nothing but
// white space may follow the value. A number is an integer when it has
// neither a fraction nor an exponent and fits 64 bits; no other number's
// value is kept, since nothing in Swan reads one.

pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Num,
    Str(Vec<u8>),
    Arr,
    Obj,
}

// A node is a link to its next sibling, a link to its first child (none
// but in a container), its key (empty in an array) and its value.
struct Node {
    next: Option<usize>,
    first: Option<usize>,
    key: Vec<u8>,
    val: Value,
}

// A parsed text: its nodes in text order, the root first.
pub struct Doc {
    nodes: Vec<Node>,
}

fn is_space(c: u8) -> bool {
    c == b' ' || c == b'\n' || c == b'\r' || c == b'\t'
}

// The first position at or after pos that is not white space.
fn skip_space(text: &[u8], pos: usize) -> usize {
    let mut p = pos;
    while p < text.len() && is_space(text[p]) {
        p += 1;
    }
    p
}

// The string whose opening quote is at text[at - 1], from its first byte:
// the position of its closing quote, and whether it holds an escape. None
// if it is unterminated or holds a raw control character.
fn scan_string(text: &[u8], at: usize) -> Option<(usize, bool)> {
    let mut pos = at;
    let mut escaped = false;
    while pos < text.len() {
        let c = text[pos];
        if c == b'"' {
            return Some((pos, escaped));
        }
        if c == b'\\' {
            escaped = true;
            pos += 2;
            continue;
        }
        if c < 0x20 {
            return None;
        }
        pos += 1;
    }
    None
}

fn hex_digit(c: u8) -> i64 {
    match c {
        b'0'..=b'9' => (c - b'0') as i64,
        b'a'..=b'f' => (c - b'a') as i64 + 10,
        b'A'..=b'F' => (c - b'A') as i64 + 10,
        _ => -1,
    }
}

fn push_utf8(out: &mut Vec<u8>, cp: i64) {
    if cp < 0x80 {
        out.push(cp as u8);
    } else if cp < 0x800 {
        out.push((0xC0 | (cp >> 6)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else if cp < 0x10000 {
        out.push((0xE0 | (cp >> 12)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    } else {
        out.push((0xF0 | (cp >> 18)) as u8);
        out.push((0x80 | ((cp >> 12) & 0x3F)) as u8);
        out.push((0x80 | ((cp >> 6) & 0x3F)) as u8);
        out.push((0x80 | (cp & 0x3F)) as u8);
    }
}

// The escaped string text[at..end] decoded; None if an escape is malformed.
fn decode_string(text: &[u8], at: usize, end: usize) -> Option<Vec<u8>> {
    let mut out: Vec<u8> = Vec::new();
    let mut pos = at;
    while pos < end {
        let c = text[pos];
        pos += 1;
        if c != b'\\' {
            out.push(c);
            continue;
        }
        let e = text[pos];
        pos += 1;
        if e == b'"' || e == b'\\' || e == b'/' {
            out.push(e);
        } else if e == b'n' {
            out.push(b'\n');
        } else if e == b't' {
            out.push(b'\t');
        } else if e == b'r' {
            out.push(b'\r');
        } else if e == b'b' {
            out.push(8);
        } else if e == b'f' {
            out.push(12);
        } else if e == b'u' {
            if pos + 4 > end {
                return None;
            }
            let mut cp: i64 = 0;
            for i in 0..4 {
                let d = hex_digit(text[pos + i]);
                if d < 0 {
                    return None;
                }
                cp = cp * 16 + d;
            }
            pos += 4;
            // A surrogate pair is two escapes that make one code point; a
            // lone half is kept as the three bytes of its own code.
            if (0xD800..0xDC00).contains(&cp) && pos + 6 <= end && text[pos] == b'\\' && text[pos + 1] == b'u' {
                let mut lo: i64 = 0;
                for i in 0..4 {
                    let d = hex_digit(text[pos + 2 + i]);
                    if d < 0 {
                        return None;
                    }
                    lo = lo * 16 + d;
                }
                if (0xDC00..0xE000).contains(&lo) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    pos += 6;
                }
            }
            push_utf8(&mut out, cp);
        } else {
            return None;
        }
    }
    Some(out)
}

// The number at text[at..]: where it ends, and its value when it is an
// integer. None when no number starts there.
fn scan_number(text: &[u8], at: usize) -> Option<(usize, Option<i64>)> {
    let digit = |p: usize| p < text.len() && text[p].is_ascii_digit();
    let mut pos = at;
    let mut neg = false;
    if pos < text.len() && text[pos] == b'-' {
        neg = true;
        pos += 1;
    }
    let int_start = pos;
    while digit(pos) {
        pos += 1;
    }
    let int_digits = pos - int_start;
    if !(int_digits > 0 && (int_digits == 1 || text[int_start] != b'0')) {
        return None;
    }
    let mut whole = true;
    if pos < text.len() && text[pos] == b'.' {
        pos += 1;
        let frac_start = pos;
        while digit(pos) {
            pos += 1;
        }
        if pos == frac_start {
            return None;
        }
        whole = false;
    }
    if pos < text.len() && (text[pos] == b'e' || text[pos] == b'E') {
        let mut p = pos + 1;
        if p < text.len() && (text[p] == b'-' || text[p] == b'+') {
            p += 1;
        }
        let start = p;
        while digit(p) {
            p += 1;
        }
        if p == start {
            return None;
        }
        pos = p;
        whole = false;
    }
    let mut int = None;
    if whole && int_digits <= 19 {
        let mut mant: u128 = 0;
        for &c in &text[int_start..int_start + int_digits] {
            mant = mant * 10 + (c - b'0') as u128;
        }
        let max = i64::MAX as u128;
        if mant <= max {
            int = Some(if neg { -(mant as i64) } else { mant as i64 });
        } else if neg && mant == max + 1 {
            int = Some(i64::MIN);
        }
    }
    Some((pos, int))
}

// The string whose opening quote is at *pos, and the position past it.
fn string(text: &[u8], pos: &mut usize) -> Option<Vec<u8>> {
    let start = *pos + 1;
    let (end, escaped) = scan_string(text, start)?;
    *pos = end + 1;
    if !escaped {
        return Some(text[start..end].to_vec());
    }
    decode_string(text, start, end)
}

fn word(text: &[u8], pos: &mut usize, w: &[u8]) -> Option<()> {
    if !(*pos + w.len() <= text.len() && &text[*pos..*pos + w.len()] == w) {
        return None;
    }
    *pos += w.len();
    Some(())
}

// Parses text; None where it stops being JSON. The parse is one loop over
// the values in text order, with the innermost container in locals and the
// ones around it on a stack. Each node is linked from its previous sibling,
// or its parent, as it is pushed.
pub fn parse(text: &[u8]) -> Option<Doc> {
    let mut pos = 0;
    let mut nodes: Vec<Node> = Vec::new();
    let mut parent: Option<usize> = None; // the innermost container,
    let mut last: Option<usize> = None; // its last child so far,
    let mut is_obj = false; // and whether it is an object
    let mut outer: Vec<(Option<usize>, Option<usize>, bool)> = Vec::new(); // the containers around it, innermost last
    let mut member = false; // whether the value at the cursor has a key
    loop {
        let mut key: Vec<u8> = Vec::new();
        if member {
            // An object member's key and its colon.
            pos = skip_space(text, pos);
            if !(pos < text.len() && text[pos] == b'"') {
                return None;
            }
            key = string(text, &mut pos)?;
            pos = skip_space(text, pos);
            if !(pos < text.len() && text[pos] == b':') {
                return None;
            }
            pos += 1;
        }
        pos = skip_space(text, pos);
        if pos >= text.len() {
            return None;
        }
        let c = text[pos];
        let val = match c {
            b'{' => Value::Obj,
            b'[' => Value::Arr,
            b'"' => Value::Str(string(text, &mut pos)?),
            b't' => {
                word(text, &mut pos, b"true")?;
                Value::Bool(true)
            }
            b'f' => {
                word(text, &mut pos, b"false")?;
                Value::Bool(false)
            }
            b'n' => {
                word(text, &mut pos, b"null")?;
                Value::Null
            }
            _ => {
                let (end, int) = scan_number(text, pos)?;
                pos = end;
                match int {
                    Some(v) => Value::Int(v),
                    None => Value::Num,
                }
            }
        };
        let node = nodes.len();
        nodes.push(Node { next: None, first: None, key, val });
        if let Some(l) = last {
            nodes[l].next = Some(node);
        } else if let Some(p) = parent {
            nodes[p].first = Some(node);
        }
        last = Some(node);
        if c == b'{' || c == b'[' {
            outer.push((parent, last, is_obj));
            parent = Some(node);
            last = None;
            is_obj = c == b'{';
            pos = skip_space(text, pos + 1);
            if pos >= text.len() || text[pos] != (if is_obj { b'}' } else { b']' }) {
                member = is_obj;
                continue;
            }
        } else {
            pos = skip_space(text, pos);
        }
        // Past a value: each close bracket completes the innermost container,
        // and a comma starts the next value.
        let mut more = false;
        while !outer.is_empty() && pos < text.len() {
            let d = text[pos];
            if d == b',' {
                pos += 1;
                more = true;
                break;
            }
            if d != (if is_obj { b'}' } else { b']' }) {
                return None;
            }
            pos += 1;
            let (p, l, o) = outer.pop()?;
            parent = p;
            last = l;
            is_obj = o;
            pos = skip_space(text, pos);
        }
        if more {
            member = is_obj;
            continue;
        }
        if !outer.is_empty() || pos != text.len() {
            return None;
        }
        return Some(Doc { nodes });
    }
}

impl Doc {
    pub fn root(&self) -> Option<usize> {
        if self.nodes.is_empty() {
            None
        } else {
            Some(0)
        }
    }

    // The first member of object n named key; None if there is none, or if
    // n is no object or None itself, so that lookups chain.
    pub fn member(&self, n: Option<usize>, key: &[u8]) -> Option<usize> {
        let n = n?;
        if !matches!(self.nodes[n].val, Value::Obj) {
            return None;
        }
        let mut c = self.nodes[n].first;
        while let Some(i) = c {
            if self.nodes[i].key == key {
                return Some(i);
            }
            c = self.nodes[i].next;
        }
        None
    }

    // Each element of an array or member of an object, in order.
    pub fn each(&self, n: usize) -> impl Iterator<Item = usize> + '_ {
        let mut c = self.nodes[n].first;
        std::iter::from_fn(move || {
            let i = c?;
            c = self.nodes[i].next;
            Some(i)
        })
    }

    // An integer's value; None for anything else, a number with a fraction
    // or an exponent included.
    #[allow(dead_code)]
    pub fn as_i64(&self, n: Option<usize>) -> Option<i64> {
        match self.nodes[n?].val {
            Value::Int(v) => Some(v),
            _ => None,
        }
    }

    pub fn as_bool(&self, n: Option<usize>) -> Option<bool> {
        match self.nodes[n?].val {
            Value::Bool(v) => Some(v),
            _ => None,
        }
    }

    // A string's text; None for anything else.
    pub fn as_string(&self, n: Option<usize>) -> Option<&[u8]> {
        match &self.nodes[n?].val {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    // The value at n in the words of scripts/port-json.goose, for the
    // comparison with Goose's reader (rust/src/bin/port-json.rs).
    #[allow(dead_code)]
    pub fn dump(&self, n: usize, out: &mut Vec<u8>) {
        fn hex(out: &mut Vec<u8>, s: &[u8]) {
            for &c in s {
                out.push(b"0123456789abcdef"[(c >> 4) as usize]);
                out.push(b"0123456789abcdef"[(c & 15) as usize]);
            }
        }
        match &self.nodes[n].val {
            Value::Null => out.push(b'z'),
            Value::Bool(v) => out.push(if *v { b't' } else { b'f' }),
            Value::Int(v) => {
                out.push(b'i');
                out.extend_from_slice(v.to_string().as_bytes());
            }
            Value::Num => out.push(b'n'),
            Value::Str(s) => {
                out.push(b's');
                hex(out, s);
            }
            Value::Arr => {
                out.push(b'[');
                for c in self.each(n) {
                    self.dump(c, out);
                    out.push(b' ');
                }
                out.push(b']');
            }
            Value::Obj => {
                out.push(b'{');
                for c in self.each(n) {
                    hex(out, &self.nodes[c].key);
                    out.push(b':');
                    self.dump(c, out);
                    out.push(b' ');
                }
                out.push(b'}');
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(text: &str) -> bool {
        parse(text.as_bytes()).is_some()
    }

    // What the reader takes and refuses. scripts/port-json.sh compares it
    // with Goose's own json::parse on these texts and more.
    #[test]
    fn takes_and_refuses_what_goose_does() {
        for t in ["{}", "[]", " 1 ", "-0", "0", "1.5", "1e5", "1E+5", "1.5e-3", "\"a\"", "true", "false", "null", "[1,2,[3,{\"a\":null}]]", "{\"a\":{\"b\":[]}}\n", "\"\\u00e9\\ud83d\\ude00\\ud800\"", "9223372036854775808", "[\"\\/\"]"] {
            assert!(ok(t), "should parse: {t}");
        }
        for t in ["", " ", "{", "[1,]", "{\"a\"}", "{\"a\":}", "{a:1}", "01", "1.", ".5", "-", "+1", "1e", "1e+", "tru", "nul", "\"a", "\"\\x\"", "\"\\u12\"", "\"\\u12g4\"", "\"a\nb\"", "1 2", "[1 2]", "{\"a\":1,}", "[1]]", "'a'"] {
            assert!(!ok(t), "should not parse: {t}");
        }
    }

    #[test]
    fn reads_members_in_order() {
        let d = parse(br#"{"a":[10,-2,9223372036854775807,-9223372036854775808,1.0,9223372036854775808],"s":"x\ty\u00e9","b":true,"a":"second"}"#).unwrap();
        let a = d.member(d.root(), b"a");
        let got: Vec<Option<i64>> = d.each(a.unwrap()).map(|n| d.as_i64(Some(n))).collect();
        assert_eq!(got, vec![Some(10), Some(-2), Some(i64::MAX), Some(i64::MIN), None, None]);
        assert_eq!(d.as_string(d.member(d.root(), b"s")), Some(&b"x\ty\xc3\xa9"[..]));
        assert_eq!(d.as_bool(d.member(d.root(), b"b")), Some(true));
        assert_eq!(d.as_bool(d.member(d.root(), b"s")), None);
        assert_eq!(d.member(d.root(), b"none"), None);
        assert_eq!(d.member(a, b"x"), None); // an array has no members
    }
}
