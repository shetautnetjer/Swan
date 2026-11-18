// Maps fixtures/tiny-rs with rust-analyzer and checks the two Rust repairs:
// trait impls recovered from rust-analyzer's symbol names, and uses inside
// nested macro calls found by name. (Was tests/rust_check.ts.)

import std;
import os;
import json;
import .harness;

// A repo that pins a toolchain rustup does not have is still mapped, with
// the default one, and the map says so.
fn rust_pinned_toolchain() {
    let w = "data/rs-pinned";
    rm_rf(w);
    mkdir_p(w);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-rs", str(w, "/repo")]), "", o) else { return; }
    write_file(str(w, "/repo/rust-toolchain.toml"), "[toolchain]\nchannel = \"1.61.0\"\n");
    var e: u8[>..] = [];
    let code = run(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/map")]), "", o, e);
    var t: u8[>..] = [];
    var e2: u8[>..] = [];
    run(argv(["bin/swan", "query", str(w, "/map/swan.db"), "impls", "Area"]), "", t, e2);
    check("a pinned toolchain that is not installed: mapped with the default one, and said so",
          code == 0 && find(e, "pins toolchain 1.61.0, which is not installed; indexing with") >= 0 &&
          find(t, "Tile") >= 0 && find(t, "Disc") >= 0, str(e[..min(e.len, 600)], "\n", t));
}

fn rust_suite() {
    rust_pinned_toolchain();
    var out: u8[>..] = [];
    guard sh(argv(["scripts/index-repo.sh", "fixtures/tiny-rs", "data/tiny-rs"]), "", out) else { return; }

    var t1: u8[>..] = [];
    guard sh(argv(["bin/swan", "query", "data/tiny-rs/swan.db", "impls", "Area"]), "", t1) else { return; }
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let r1, e1 = json::parse(t1, d1, x1);
    var names: u8[>..] = [];
    let l1 = json::member(r1, "implementations");
    if l1 { json::each(l1) { s => format(names, jstr(s, "name_path"), "\n"); }; }
    let impls = sorted_join(names);
    check("find_implementations Area: Tile and Disc", impls == "Disc,Tile", impls);

    var t2: u8[>..] = [];
    guard sh(argv(["bin/swan", "query", "data/tiny-rs/swan.db", "hierarchy", "Area/area"]), "", t2) else { return; }
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let r2, e2 = json::parse(t2, d2, x2);
    names.clear();
    let l2 = json::member(r2, "subtypes");
    if l2 { json::each(l2) { s => format(names, jstr(s, "name_path"), "\n"); }; }
    let area = sorted_join(names);
    check("the trait method's implementations are Tile/area and Disc/area", area == "Disc/area,Tile/area", area);

    var t3: u8[>..] = [];
    guard sh(argv(["bin/swan", "query", "data/tiny-rs/swan.db", "symbol", "Tile/new"]), "", t3) else { return; }
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let r3, e3 = json::parse(t3, d3, x3);
    check("impl methods are named by their type: Tile/new", jcount(r3) == 1, t3);

    var t4: u8[>..] = [];
    guard sh(argv(["bin/swan", "query", "data/tiny-rs/swan.db", "uses", "/Shape"]), "", t4) else { return; }
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let r4, e4 = json::parse(t4, d4, x4);
    let shape = json::member(nth(r4, 0), "references");
    var sq = false; var circ = false;
    if shape {
        json::each(shape) { r =>
            if jint(r, "line") == 42 && jstr(r, "via") == "Shape/Square" { sq = true; }
            if jint(r, "line") == 55 { circ = true; }
        };
    }
    // rust-analyzer resolves uses inside vec![...] since its 2026-10 builds;
    // older ones left them to Swan's by-name fallback. Either way it must be
    // found. (From #37.)
    check("Shape::Square inside vec![...] counts as a use of Shape (compiler-resolved or by name)", sq, t4);
    check("Shape::Circle inside assert!(matches!(...)) is found too", circ, t4);

    var t5: u8[>..] = [];
    guard sh(argv(["bin/swan", "query", "data/tiny-rs/swan.db", "uses", "/Tile"]), "", t5) else { return; }
    var d5: json::Node[>..] = []; var x5: u8[>..] = [];
    let r5, e5 = json::parse(t5, d5, x5);
    var tile = false;
    let tr = json::member(nth(r5, 0), "references");
    if tr {
        json::each(tr) { r => if jint(r, "line") == 56 && jstr(r, "via") == "Tile/new" { tile = true; } };
    }
    check("Tile::new inside vec![...] counts as a use of Tile", tile, t5);
}
