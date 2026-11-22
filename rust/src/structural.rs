// Structural search, ast-grep style: `$X.unwrap()` finds every call of
// unwrap on anything, by the syntax tree rather than by text, in every
// language Swan bundles a tree-sitter grammar for. Each match is tied to the
// symbol it sits in, from the map. Carried over from src/structural.goose;
// the rewrite (rewrite_pattern) is an edit and comes with stage 6.

use crate::db::Db;
use crate::fresh::Fresh;
use crate::query::meta_value;
use crate::sys;
use crate::treesitter::{language_of_path, Pattern};
use crate::util::{find, json_string, push_int, split};

const STRUCT_LANGS: [&[u8]; 17] = [
    b"typescript", b"tsx", b"javascript", b"python", b"rust", b"java", b"c", b"cpp", b"cuda", b"kotlin", b"lua", b"glsl",
    b"hlsl", b"wgsl", b"gdscript", b"csharp", b"php",
];

// The repo's files under rel with a grammar (of `lang`, if given), relative
// to the repo, one per line.
fn structural_files(fr: &Fresh, root: &[u8], rel: &[u8], lang: &[u8]) -> Vec<u8> {
    let mut files: Vec<u8> = Vec::new();
    let base: Vec<u8> = if !rel.is_empty() { [root, b"/", rel].concat() } else { root.to_vec() };
    let mut take = |full: &[u8]| {
        let l = language_of_path(full);
        if !l.is_empty() && (lang.is_empty() || l == lang) {
            files.extend_from_slice(&full[root.len() + 1..]);
            files.push(b'\n');
        }
    };
    if sys::file_exists(&base) {
        take(&base);
    } else {
        fr.walk.each_file(&base, |full, _| take(full));
    }
    files
}

fn first_line(s: &[u8]) -> &[u8] {
    let nl = find(s, b"\n");
    let one = if nl >= 0 { &s[..nl as usize] } else { s };
    if one.len() > 200 {
        &one[..200]
    } else {
        one
    }
}

fn count_newlines(s: &[u8]) -> i64 {
    s.iter().filter(|&&c| c == b'\n').count() as i64
}

pub fn search_pattern(db: &Db, fr: &Fresh, pattern: &[u8], lang: &[u8], rel: &[u8], limit: i64, out: &mut Vec<u8>) -> bool {
    if pattern.is_empty() {
        out.extend_from_slice(b"pattern is required");
        return false;
    }
    let mut root = meta_value(db, b"root");
    if root.is_empty() {
        out.extend_from_slice(b"the map does not record its repo; rebuild it with swan map");
        return false;
    }
    if root[root.len() - 1] == b'/' {
        root.pop();
    }
    let files = structural_files(fr, &root, rel, lang);
    let mut skipped: Vec<u8> = Vec::new();
    let mut searched: i64 = 0;
    let mut n: i64 = 0;
    let mut body: Vec<u8> = Vec::new();
    let mut pat = Pattern::default();
    for l in STRUCT_LANGS {
        let mut mine: Vec<u8> = Vec::new(); // relative, one per line
        let mut paths: Vec<Vec<u8>> = Vec::new(); // absolute
        let mut count = 0;
        for f in files.split(|&c| c == b'\n') {
            if !f.is_empty() && language_of_path(f) == l {
                mine.extend_from_slice(f);
                mine.push(b'\n');
                paths.push([&root[..], b"/", f].concat());
                count += 1;
            }
        }
        if count == 0 {
            continue;
        }
        let mut why: Vec<u8> = Vec::new();
        if !pat.compile(l, pattern, &mut why) {
            if !skipped.is_empty() {
                skipped.push(b',');
            }
            skipped.extend_from_slice(b"{\"language\":");
            json_string(&mut skipped, l);
            skipped.extend_from_slice(b",\"why\":");
            json_string(&mut skipped, &why);
            skipped.push(b'}');
            continue;
        }
        searched += count;
        let rels = split(&mine, b'\n');
        // Per file, once: its text, whether it is stale, and its symbols'
        // bodies, to name the symbol each match sits in.
        let refs: Vec<&[u8]> = paths.iter().map(|p| &p[..]).collect();
        for (idx, matches) in pat.search_files(&refs).into_iter().enumerate() {
            if matches.is_empty() {
                continue;
            }
            let f = rels[idx];
            let mut text: Vec<u8> = Vec::new();
            sys::read_file(&[&root[..], b"/", f].concat(), &mut text);
            let stale_file = fr.is_stale(f);
            let mut spans: Vec<i64> = Vec::new(); // body_start, body_end, offset of its name in names
            let mut names: Vec<u8> = Vec::new();
            let st = db.prepare_or_die(b"SELECT body_start, body_end, name_path FROM symbols WHERE def_file = ?1 AND body_start IS NOT NULL");
            st.bind_text(1, f);
            while st.step_checked() {
                spans.push(st.col_int(0));
                spans.push(st.col_int(1));
                spans.push(names.len() as i64);
                names.extend_from_slice(&st.col_text(2));
                names.push(b'\n');
            }
            drop(st);
            for m in matches {
                n += 1;
                if !(n <= limit && m.end <= text.len() as i64) {
                    continue;
                }
                let (s0, e0, r, c) = (m.start, m.end, m.row, m.col);
                let mt = &text[s0 as usize..e0 as usize];
                if n > 1 {
                    body.push(b',');
                }
                body.extend_from_slice(b"{\"relative_path\":");
                json_string(&mut body, f);
                body.extend_from_slice(b",\"line\":");
                push_int(&mut body, r + 1);
                body.extend_from_slice(b",\"column\":");
                push_int(&mut body, c + 1);
                body.extend_from_slice(b",\"end_line\":");
                push_int(&mut body, r + count_newlines(mt) + 1);
                body.extend_from_slice(b",\"text\":");
                json_string(&mut body, first_line(mt));
                body.extend_from_slice(b",\"captures\":{");
                let mut k = 0;
                for one in m.captures.split(|&c| c == 0x1e) {
                    let sep = find(one, b"\x1f");
                    if sep >= 0 {
                        if k > 0 {
                            body.push(b',');
                        }
                        k += 1;
                        json_string(&mut body, &one[..sep as usize]);
                        body.push(b':');
                        json_string(&mut body, first_line(&one[sep as usize + 1..]));
                    }
                }
                body.push(b'}');
                // The innermost body holding the line (on a tie, the later start).
                let mut best: i64 = -1;
                let mut j = 0;
                while j + 3 <= spans.len() {
                    let b = best as usize;
                    if spans[j] <= r
                        && spans[j + 1] >= r
                        && (best < 0
                            || spans[j + 1] - spans[j] < spans[b + 1] - spans[b]
                            || (spans[j + 1] - spans[j] == spans[b + 1] - spans[b] && spans[j] > spans[b]))
                    {
                        best = j as i64;
                    }
                    j += 3;
                }
                if best >= 0 {
                    let at = spans[best as usize + 2] as usize;
                    let nl = at + find(&names[at..], b"\n") as usize;
                    body.extend_from_slice(b",\"in_symbol\":");
                    json_string(&mut body, &names[at..nl]);
                }
                if stale_file {
                    body.extend_from_slice(b",\"stale\":true");
                }
                body.push(b'}');
            }
        }
    }
    out.extend_from_slice(b"{\"pattern\":");
    json_string(out, pattern);
    out.extend_from_slice(b",\"matches\":[");
    out.extend_from_slice(&body);
    out.extend_from_slice(b"],\"count\":");
    push_int(out, n);
    out.extend_from_slice(b",\"files_searched\":");
    push_int(out, searched);
    if n > limit {
        out.extend_from_slice(b",\"truncated\":true");
    }
    if !skipped.is_empty() {
        out.extend_from_slice(b",\"pattern_does_not_parse_in\":[");
        out.extend_from_slice(&skipped);
        out.push(b']');
    }
    out.push(b'}');
    true
}
