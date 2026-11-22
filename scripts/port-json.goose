// The port's JSON dumper (stage 4, docs/rust-port.md): each file given, as
// Goose's json::parse reads it. rust/src/bin/port-json.rs prints what the
// Rust program's reader (rust/src/json.rs) makes of it in the same words;
// the same bytes from both mean the same texts taken and refused, the same
// members in the same order, and the same strings and integers.
//
//   port-json <file>...
//
// "path\trefused" for a text that is not JSON (or cannot be read), else
// "path\t" and the value: z null, t and f, i<integer>, n for any other
// number, s<the string's bytes in hex>, [ values ], { <key in hex>:value }.
import std;
import os;
import json;

let HEX = "0123456789abcdef";

fn hex(out: u8[>..]&, s: const u8[:]) {
    for c in s { out.push(HEX[(c >> 4) as i64]); out.push(HEX[(c & 15) as i64]); }
}

recursive fn dump(n: json::Node&, out: u8[>..]&) {
    match n.val {
        Null => { out.push('z'); },
        Bool b => { out.push(if b.v { 't' } else { 'f' }); },
        Int i => { format(out, "i", i.v); },
        Num x => { out.push('n'); },
        Str t => { out.push('s'); hex(out, t.s); },
        Arr a => {
            out.push('[');
            json::each(n) { c => dump(c, out); out.push(' '); };
            out.push(']');
        },
        Obj o => {
            out.push('{');
            json::each(n) { c => hex(out, c.key); out.push(':'); dump(c, out); out.push(' '); };
            out.push('}');
        },
    }
}

fn main() {
    let a = args();
    var out: u8[>..] = [];
    for i in 1..a.len {
        var text: u8[>..] = [];
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        if !read_file(a[i], text) { format(out, a[i], "\trefused\n"); continue; }
        let root, err = json::parse(text, doc, dec);
        if root {
            format(out, a[i], "\t");
            dump(root, out);
            // The first member named "a", when the text is an object with one:
            // a second "a" is never the one found.
            let first = json::member(root, "a");
            if first { out.append("\ta="); dump(first, out); }
            out.push('\n');
        } else {
            format(out, a[i], "\trefused\n");
        }
        if out.len > 1048576 { write_stdout(out); out.clear(); }
    }
    write_stdout(out);
}
