// The port's JSON dumper (stage 4, docs/rust-port.md): each file given, as
// the Rust program's reader (rust/src/json.rs) reads it, in the words of
// scripts/port-json.goose, which prints what Goose's json::parse makes of
// it. The same bytes from both mean the same texts taken and refused, the
// same members in the same order, and the same strings and integers.
//
//   port-json <file>...
//
// "path\trefused" for a text that is not JSON (or cannot be read), else
// "path\t" and the value: z null, t and f, i<integer>, n for any other
// number, s<the string's bytes in hex>, [ values ], { <key in hex>:value }.

#[allow(dead_code)]
#[path = "../json.rs"]
mod json;

use std::io::Write;
use std::os::unix::ffi::OsStrExt;

fn main() {
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for arg in std::env::args_os().skip(1) {
        let mut line: Vec<u8> = arg.as_bytes().to_vec();
        line.push(b'\t');
        match std::fs::read(&arg).ok().and_then(|text| json::parse(&text)) {
            Some(doc) => {
                if let Some(root) = doc.root() {
                    doc.dump(root, &mut line);
                }
                // The first member named "a", when the text is an object
                // with one: a second "a" is never the one found.
                if let Some(first) = doc.member(doc.root(), b"a") {
                    line.extend_from_slice(b"\ta=");
                    doc.dump(first, &mut line);
                }
            }
            None => line.extend_from_slice(b"refused"),
        }
        line.push(b'\n');
        let _ = out.write_all(&line);
    }
    let _ = out.flush();
}
