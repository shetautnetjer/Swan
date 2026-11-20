// The port's tree dumper (stage 3, docs/rust-port.md): the tree-sitter tree
// of each file given, as the Rust program parses it, in the words of
// scripts/port-trees.goose, which prints the Goose program's. The same bytes
// from both mean the same grammars, runtime and shim.
//
//   port-trees <file>...
//
// "path\tlanguage\tnodes", then one line of the eight numbers of each node;
// "path\t-" for a file with no grammar or that cannot be read.

#[allow(dead_code)]
#[path = "../treesitter.rs"]
mod treesitter;

use std::io::Write;
use std::os::unix::ffi::OsStrExt;

fn main() {
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for arg in std::env::args_os().skip(1) {
        let p = arg.as_bytes();
        let lang = treesitter::language_of_path(p);
        let text = if lang.is_empty() { None } else { std::fs::read(&arg).ok() };
        let Some(text) = text else {
            let _ = out.write_all(&[p, b"\t-\n"].concat());
            continue;
        };
        let mut nodes: Vec<i32> = Vec::new();
        if !treesitter::parse(lang, &text, &mut nodes) {
            let _ = out.write_all(&[p, b"\t", lang, b"\tno grammar\n"].concat());
            continue;
        }
        let n = nodes.len() / treesitter::R;
        let _ = out.write_all(&[p, b"\t", lang, b"\t", n.to_string().as_bytes(), b"\n"].concat());
        for k in 0..n {
            let row = &nodes[k * treesitter::R..(k + 1) * treesitter::R];
            let line: Vec<String> = row.iter().map(|v| v.to_string()).collect();
            let _ = out.write_all(line.join(" ").as_bytes());
            let _ = out.write_all(b"\n");
        }
    }
    let _ = out.flush();
}
