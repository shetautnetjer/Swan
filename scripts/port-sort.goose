// The port's sort dumper (stage 4, docs/rust-port.md): each list in the
// files given, sorted by Goose's sort. rust/src/bin/port-sort.rs sorts the
// same lists with the Rust program's copy of it (rust/src/gsort.rs) and
// prints the answer in the same words; the same bytes from both mean the
// same order, elements that compare as equal included.
//
//   port-sort <file>...
//
// A line of a file is a list: "<a|d><shift> key key ...". What is sorted is
// the places 0, 1, 2, ... of the keys, a place before another when its key,
// shifted right by <shift> bits, is the smaller (a) or the larger (d). A
// line of the answer is the places in their sorted order.
import std;
import os;

fn sorted(mode: u8, shift: i64, keys: const i64[:], out: u8[>..]&) {
    var order: i64[>..] = [];
    for z, i in keys { order.push(i); }
    if mode == 'd' { sort(order) { a, b => (keys[a] >> shift) > (keys[b] >> shift) }; }
    else { sort(order) { a, b => (keys[a] >> shift) < (keys[b] >> shift) }; }
    for i in order { format(out, i, " "); }
    out.push('\n');
}

fn main() {
    let a = args();
    var out: u8[>..] = [];
    for i in 1..a.len {
        var text: u8[>..] = [];
        if !read_file(a[i], text) { format(out, a[i], "\tunread\n"); continue; }
        each_split(text, '\n') { line =>
            guard line.len >= 2;
            let f = split(line, ' ');
            let shift, shift_ok = parse_int(f[0][1..]);
            var keys: i64[>..] = [];
            for t, j in f {
                if j > 0 && t.len > 0 {
                    let k, k_ok = parse_int(t);
                    keys.push(k);
                }
            }
            sorted(line[0], shift, keys, out);
            if out.len > 1048576 { write_stdout(out); out.clear(); }
        };
    }
    write_stdout(out);
}
