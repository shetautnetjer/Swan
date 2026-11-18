// Swan's reachability memo for scip-python's bundled pyright
// (src/pypatch.goose): the patched indexer must write exactly what the
// unpatched one writes, and must not take minutes on the shape of file the
// memo is for. A copy of the indexer is reverted to compare with.

import std;
import os;
import .harness;

// A script of n `threw = False / try / except / assert threw` blocks, with
// the other flow shapes the memo guards: try/finally, a context manager, a
// call that never returns, and a reassigned variable narrowed by asserts.
fn pp_script(n: i64) -> u8[>..] {
    var t: u8[>..] = [];
    t.append("import math\nimport sys\n\n\ndef stop() -> None:\n    sys.exit(1)\n\n\n");
    for i in n {
        format(t, "threw = False\ntry:\n    math.floor(float('inf'))\nexcept OverflowError:\n    threw = True\nassert threw\n");
        format(t, "r = math.nextafter(", i, ".0, 2.0)\nassert r > ", i, ".0\n\n");
        if i % 10 == 3 {
            format(t, "try:\n    r = math.sqrt(", i, ")\nfinally:\n    threw = False\nassert not threw\n\n");
        }
        if i % 10 == 6 {
            format(t, "with open('x", i, "') as fh:\n    data = fh.read()\n    if not data:\n        stop()\n    threw = bool(data)\nassert threw or not threw\n\n");
        }
    }
    return t;
}

// Runs one indexer (the package folder's index.js) on a folder; ms taken,
// or -1 if it failed.
fn pp_index(pkg: const u8[:], repo: const u8[:], out: const u8[:]) -> i64 {
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    let t0 = clock();
    let code = run_at(argv(["node", str(pkg, "/index.js"), "index", ".", "--quiet", "--project-name", "p", "--project-version", "0", "--output", out]),
                      repo, "", o, e);
    return if code == 0 { ((clock() - t0) * 1000.0) as i64 } else { -1 };
}

fn pypatch_suite() {
    var cwd: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["realpath", "."]), "", cwd, e);
    let here = trim(cwd);
    let pkg = str(here, "/tools/node_modules/@sourcegraph/scip-python");
    let bundle = str(pkg, "/dist/pyright-internal.js");
    if !file_exists(bundle) { print("skipped: no scip-python in tools/node_modules"); return; }
    var tmpo: u8[>..] = [];
    run(argv(["mktemp", "-d", "-t", "swan-pypatch-XXXXXX"]), "", tmpo, e);
    var tmp: u8[>..] = [];
    tmp.append(trim(tmpo));
    var o: u8[>..] = [];

    // Two copies, one with the memo and one without. The installed
    // indexer is only read: patching it here would undo a deliberate
    // SWAN_SCIP_PYTHON_PATCH=0 and could cross a map that is running.
    let patched = str(tmp, "/patched");
    guard sh(argv(["cp", "-r", pkg, patched]), "", o) else { rm_rf(tmp); return; }
    let bundle2 = str(patched, "/dist/pyright-internal.js");
    var r: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", bundle2]), "", r, e);
    var text: u8[>..] = [];
    read_file(bundle2, text);
    check("Swan's scip-python has the reachability memo", find(text, "__swanReach") >= 0, r);

    // A reverted copy, to compare with.
    let plain = str(tmp, "/plain");
    guard sh(argv(["cp", "-r", patched, plain]), "", o) else { rm_rf(tmp); return; }
    var rv: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", str(plain, "/dist/pyright-internal.js"), "--revert"]), "", rv, e);
    var ptext: u8[>..] = [];
    read_file(str(plain, "/dist/pyright-internal.js"), ptext);
    check("the patch reverts cleanly on a copy", trim(rv) == "reverted" && find(ptext, "__swanReach") < 0, rv);
    var again: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", bundle2]), "", again, e);
    check("applying it twice changes nothing", trim(again) == "already", again);
    write_file(str(tmp, "/other.js"), "function v(){}\n");
    var bad_o: u8[>..] = [];
    let bad = run(argv(["bin/swan", "scip-python-patch", str(tmp, "/other.js")]), "", bad_o, e);
    var other: u8[>..] = [];
    read_file(str(tmp, "/other.js"), other);
    check("a file it does not fit is left alone", bad != 0 && other == "function v(){}\n", bad_o);

    // The second fix, on scip-python.js: package names and the Python
    // version. On a copy of that one file, so the two packages compared
    // below stay alike in everything but the memo.
    mkdir_p(str(tmp, "/names"));
    let names2 = str(tmp, "/names/scip-python.js");
    guard sh(argv(["cp", str(pkg, "/dist/scip-python.js"), names2]), "", o) else { rm_rf(tmp); return; }
    var shipped: u8[>..] = [];
    var s1: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", names2, "--revert"]), "", s1, e);
    read_file(names2, shipped);
    var s2: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", names2]), "", s2, e);
    var fixed: u8[>..] = [];
    read_file(names2, fixed);
    var s3: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", names2]), "", s3, e);
    var s4: u8[>..] = [];
    run(argv(["bin/swan", "scip-python-patch", names2, "--revert"]), "", s4, e);
    var back: u8[>..] = [];
    read_file(names2, back);
    check("Swan's second scip-python fix goes on a copy of scip-python.js, once, and comes off leaving the file as it shipped",
          trim(s2) == "patched" && find(fixed, "__swanSite") >= 0 && find(fixed, "SWAN_PY_VERSION") >= 0 && trim(s3) == "already" &&
          trim(s4) == "reverted" && back == shipped && find(shipped, "__swanSite") < 0, str(s1, s2, s3, s4));

    // Same output, patched and unpatched: a fixture, and the worst-case shape.
    let fx = str(here, "/fixtures/tiny-py");
    let a1 = pp_index(patched, fx, str(tmp, "/fx-patched.scip"));
    let b1 = pp_index(plain, fx, str(tmp, "/fx-plain.scip"));
    var fa: u8[>..] = [];
    var fb: u8[>..] = [];
    read_file(str(tmp, "/fx-patched.scip"), fa);
    read_file(str(tmp, "/fx-plain.scip"), fb);
    check("fixtures/tiny-py: patched and unpatched indexers write the same index", a1 >= 0 && b1 >= 0 && fa.len > 0 && fa == fb,
          str("patched ", a1, " ms, ", fa.len, " bytes; unpatched ", b1, " ms, ", fb.len, " bytes"));

    let small = str(tmp, "/small");
    mkdir_p(small);
    write_file(str(small, "/blocks.py"), pp_script(30));
    let a2 = pp_index(patched, small, str(tmp, "/small-patched.scip"));
    let b2 = pp_index(plain, small, str(tmp, "/small-plain.scip"));
    var sa: u8[>..] = [];
    var sb: u8[>..] = [];
    read_file(str(tmp, "/small-patched.scip"), sa);
    read_file(str(tmp, "/small-plain.scip"), sb);
    check("30 try/except blocks with finally, with and a NoReturn call: the same index", a2 >= 0 && b2 >= 0 && sa.len > 0 && sa == sb,
          str("patched ", a2, " ms, ", sa.len, " bytes; unpatched ", b2, " ms, ", sb.len, " bytes"));

    // The shape that took minutes: 90 blocks is over a minute unpatched.
    let big = str(tmp, "/big");
    mkdir_p(big);
    write_file(str(big, "/blocks.py"), pp_script(90));
    let a3 = pp_index(patched, big, str(tmp, "/big-patched.scip"));
    check(str("90 try/except blocks index in seconds, not minutes (", a3, " ms)"), a3 >= 0 && a3 < 30000, str(a3, " ms"));
    rm_rf(tmp);
}
