// The port's sort dumper (stage 4, docs/rust-port.md): each list in the
// files given, sorted by the Rust program's copy of Goose's sort
// (rust/src/gsort.rs), in the words of scripts/port-sort.goose, which sorts
// the same lists with Goose's own. The same bytes from both mean the same
// order, elements that compare as equal included.
//
//   port-sort <file>...
//
// A line of a file is a list: "<a|d><shift> key key ...". What is sorted is
// the places 0, 1, 2, ... of the keys, a place before another when its key,
// shifted right by <shift> bits, is the smaller (a) or the larger (d). A
// line of the answer is the places in their sorted order.

#[path = "../gsort.rs"]
mod gsort;

use std::io::Write;
use std::os::unix::ffi::OsStrExt;

fn main() {
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for arg in std::env::args_os().skip(1) {
        let Ok(text) = std::fs::read(&arg) else {
            let _ = out.write_all(&[arg.as_bytes(), b"\tunread\n"].concat());
            continue;
        };
        for line in text.split(|&c| c == b'\n') {
            if line.len() < 2 {
                continue;
            }
            let mut words = line.split(|&c| c == b' ');
            let head = words.next().unwrap_or(b"");
            let number = |w: &[u8]| std::str::from_utf8(w).ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
            let shift = number(&head[1..]);
            let keys: Vec<i64> = words.filter(|w| !w.is_empty()).map(number).collect();
            let mut order: Vec<i64> = (0..keys.len() as i64).collect();
            let key = |i: i64| keys[i as usize] >> shift;
            if head[0] == b'd' {
                gsort::goose_sort(&mut order, &|a, b| key(a) > key(b));
            } else {
                gsort::goose_sort(&mut order, &|a, b| key(a) < key(b));
            }
            let mut said: Vec<u8> = Vec::new();
            for i in order {
                said.extend_from_slice(i.to_string().as_bytes());
                said.push(b' ');
            }
            said.push(b'\n');
            let _ = out.write_all(&said);
        }
    }
    let _ = out.flush();
}
