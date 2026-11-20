// The port's tree dumper (stage 3, docs/rust-port.md): the tree-sitter tree
// of each file given, as the Goose program parses it. rust/src/bin/
// port-trees.rs prints the Rust program's in the same words; the same bytes
// from both mean the same grammars, runtime and shim.
//
//   port-trees <file>...
//
// "path\tlanguage\tnodes", then one line of the eight numbers of each node;
// "path\t-" for a file with no grammar or that cannot be read.
import std;
import os;
import treesitter from "shetautnetjer/goose-treesitter@59313e9da0b9f1cce8df83cabe53ed73fa92345c";   // as src/swan.goose

fn main() {
    let a = args();
    var out: u8[>..] = [];
    for i in 1..a.len {
        let p = a[i];
        let lang = treesitter::language_of_path(p);
        var text: u8[>..] = [];
        if lang.len == 0 || !read_file(p, text) { format(out, p, "\t-\n"); continue; }
        var nodes: i32[>..] = [];
        if !treesitter::parse(lang, text[..], nodes) { format(out, p, "\t", lang, "\tno grammar\n"); continue; }
        let n = nodes.len / 8;
        format(out, p, "\t", lang, "\t", n, "\n");
        for k in 0..n {
            for j in 0..8 {
                if j > 0 { out.push(' '); }
                format(out, nodes[k * 8 + j] as i64);
            }
            out.push('\n');
        }
        if out.len > 1048576 { write_stdout(out); out.clear(); }
    }
    write_stdout(out);
}
