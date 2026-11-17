// Times `swan serve` on a real index: cold start (spawn to first answer)
// and warm latency per tool over repeated calls. Not a test; run by hand:
//
//   bin/swan-check bench <db> <name_path>...
//
// (Was tests/bench.ts.)

import std;
import os;
import json;
import .harness;

// The p-th percentile of n times (sorted in place), as the TypeScript took it.
fn bn_pct(xs: f64[:], p: f64) -> f64 {
    sort(xs) { a, b => a < b };
    let k = min(xs.len - 1, ((xs.len as f64) * p) as i64);
    return xs[k];
}
fn bn_ms(x: f64) -> u8[>..] {
    let h = (x * 100.0 + 0.5) as i64;
    var cents = h % 100;
    return str(h / 100, ".", if cents < 10 { "0" } else { "" }, cents);
}

fn bench_main(db: const u8[:], names: const u8[:]) {
    let t0 = clock();
    guard mcp_open(argv(["bin/swan", "serve", db]), "") else { return; }
    var line: u8[>..] = [];
    guard mcp_rpc("initialize", """{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bench","version":"0"}}""", line) else { mcp_close(); return; }
    var nl: u8[>..] = [];
    nl.append(names);
    let ns = split(nl, '\n');
    var first: u8[>..] = [];
    let ok = mcp_call_quiet("find_referencing_symbols", str("{\"name_path\":\"", ns[0], "\"}"), first);
    print(str("cold: spawn + initialize + first find_referencing_symbols(", ns[0], ") = ", bn_ms((clock() - t0) * 1000.0), " ms"));
    guard ok == 1 else { print(str("error: ", first)); mcp_close(); return; }
    var times: f64[>..] = [];
    var t: u8[>..] = [];
    for name in ns {
        guard name.len > 0;
        for k in 2 {
            let tool = if k == 0 { "find_symbol" } else { "find_referencing_symbols" };
            let args = if k == 0 { str("{\"name_path_pattern\":\"", name, "\"}") } else { str("{\"name_path\":\"", name, "\"}") };
            times.clear();
            var count = 0;
            for i in 50 {
                let s = clock();
                mcp_call_quiet(tool, args, t);
                times.push((clock() - s) * 1000.0);
                var d: json::Node[>..] = []; var x: u8[>..] = [];
                let v, e = json::parse(t, d, x);
                count = 0;
                if k == 0 { count = jcount(v); }
                else if v { json::each(v) { s2 => count += jcount(json::member(s2, "references")); }; }
            }
            print(str(tool, "(", name, "): ", count, " results, median ", bn_ms(bn_pct(times, 0.5)), " ms, p95 ", bn_ms(bn_pct(times, 0.95)), " ms"));
        }
    }
    mcp_close_code();
}
