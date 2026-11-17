// swan-check: Swan's tests, every suite in one Goose program. Run from the
// Swan checkout, after scripts/build.sh:
//
//   bin/swan-check            every suite
//   bin/swan-check rust split   the named suites
//   bin/swan-check bench <db> <name_path>...   timings, not a test
//
// Unlike a shell script that stops at the first failing suite, every suite
// named runs, and the totals come at the end. Exit 1 if any check failed.

import std;
import os;
import json;
import sqlite from "shetautnetjer/goose-sqlite@c759de735ae936dcbc197bb9aae40e13565ef21c";
import .harness;
import .rust_suite;
import .split_suite;
import .mcp_suite;
import .agnostic_suite;
import .diag_suite;
import .kotlin_suite;
import .game_suite;
import .live_suite;
import .trust_suite;
import .edit_suite;
import .maps_suite;
import .lang_suite;
import .structural_suite;
import .bench;

let SUITES = ["mcp", "rust", "split", "agnostic", "diag", "kotlin", "game", "live", "trust", "edit", "maps", "lang", "structural"];

fn run_suite(name: const u8[:]) -> bool {
    if name == "rust" { rust_suite(); return true; }
    if name == "split" { split_suite(); return true; }
    if name == "mcp" { mcp_suite(); return true; }
    if name == "agnostic" { agnostic_suite(); return true; }
    if name == "diag" { diag_suite(); return true; }
    if name == "kotlin" { kotlin_suite(); return true; }
    if name == "game" { game_suite(); return true; }
    if name == "live" { live_suite(); return true; }
    if name == "trust" { trust_suite(); return true; }
    if name == "edit" { edit_suite(); return true; }
    if name == "maps" { maps_suite(); return true; }
    if name == "lang" { lang_suite(); return true; }
    if name == "structural" { structural_suite(); return true; }
    return false;
}

fn main() {
    let a = args();
    if a.len >= 4 && a[1] == "bench" {
        var ns: u8[>..] = [];
        for k in 3..a.len { format(ns, a[k], "\n"); }
        bench_main(a[2], ns);
        return;
    }
    var names: u8[>..] = [];
    if a.len <= 1 { for s in SUITES { format(names, s, "\n"); } }
    else { for k in 1..a.len { format(names, a[k], "\n"); } }
    var summary: u8[>..] = [];
    var bad_suites = 0;
    each_split(names, '\n') { n =>
        guard n.len > 0;
        print(str("== ", n));
        h_suite_failures = 0;
        let t0 = clock();
        guard run_suite(n) else { print(str("unknown suite: ", n)); bad_suites++; return; };
        let ms = ((clock() - t0) * 1000.0) as i64;
        if h_suite_failures > 0 { bad_suites++; }
        format(summary, if h_suite_failures == 0 { "  pass  " } else { "  FAIL  " }, n, " (", ms / 1000, " s",
               if h_suite_failures > 0 { str(", ", h_suite_failures, " failed") } else { str("") }, ")\n");
    };
    print(str("\n", summary, h_passes, " checks passed, ", h_failures, " failed"));
    if h_failures > 0 || bad_suites > 0 { exit(1); }
}
