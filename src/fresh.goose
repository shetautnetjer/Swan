// Freshness: whether a file changed after the SCIP run the map was built
// from. Answers about such a file may be out of date, and each one says so
// with "stale": true, so an agent knows to reread the file or refresh the
// map. The check is one stat per file: modified after the SCIP run, or gone.

import std;
import os;

var fresh_root: u8[..4096];
var fresh_scip_time: i64 = 0;    // ns since the epoch; 0 when unknown

fn load_freshness(db: i64) {
    var v: u8[>..] = [];
    meta_value(db, "root", v);
    if v.len > 0 && v.len < 4000 {
        format(fresh_root, v);
        if v[v.len - 1] != '/' { fresh_root.push('/'); }
    }
    var t: u8[>..] = [];
    meta_value(db, "scip_time", t);
    let n, ok = parse_int(t);
    if ok { fresh_scip_time = n; }
}

fn is_stale(file: const u8[:]) -> bool {
    guard fresh_scip_time > 0 && fresh_root.len > 0 && file.len > 0 else { return false; }
    var p: u8[>..] = [];
    p.append(fresh_root);
    p.append(file);
    let m = swan_mtime_ns(p);
    return m < 0 || m > fresh_scip_time;
}

// The time the SCIP data was made: index.scip beside the rows, or the rows.
fn scip_time_of(dir: const u8[:]) -> i64 {
    let t = swan_mtime_ns(str(dir, "/index.scip"));
    return if t > 0 { t } else { swan_mtime_ns(str(dir, "/occurrences.tsv")) };
}
