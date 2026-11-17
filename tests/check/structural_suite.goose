// Structural search checked against ast-grep, the reference: for each case
// (language, pattern), Swan's matches and ast-grep's must be the same set of
// positions. Cases are an obligation ledger: each states what it covers.
// Runs on the fixtures; with SWAN_CHECK_DB=<map> (and optionally
// SWAN_CHECK_REL=<folder>) it runs the same cases on a real repo, read-only.
// Also checks rewrite_pattern's plan, refusal and apply on a scratch copy.
// (Was tests/structural_check.ts.)

import std;
import os;
import json;
import dictionary;
import .harness;

// lang, ast-grep's name for it ("" where ast-grep has no grammar: then
// `expect` is the answer, checked by hand), pattern, what it covers, expect.
let ST_CASES = [
    "typescript\tts\tconsole.log($$$A)\ta call with any arguments ($$$, none included)\t",
    "typescript\tts\t$X.push($Y)\ta method call on anything\t",
    "typescript\tts\tawait $X\ta unary keyword expression\t",
    "typescript\tts\tnew $C($$$A)\tconstructor calls\t",
    "typescript\tts\tif ($C) { $$$B }\ta statement with a block body\t",
    "typescript\tts\t$A === $A\ta metavariable used twice must match the same text\t",
    "typescript\tts\treturn $X\ta keyword statement is not stripped to its operand\t",
    "python\tpython\t$X.append($Y)\tPython method calls\t",
    "python\tpython\tisinstance($X, $T)\tfixed arity\t",
    "python\tpython\tdef $F($$$A): $$$B\ta whole function definition\t",
    "rust\trust\t$X.unwrap()\tan expression only valid inside a function\t",
    "rust\trust\timpl $T for $S { $$$B }\ttrait impl items\t",
    "rust\trust\tTile::new($X)\ta path call\t",
    "java\tjava\tSystem.out.println($X)\tJava statement inside a method\t",
    "java\tjava\tnew $C($$$A)\tJava object creation\t",
    "c\tc\tprintf($$$A)\tC calls\t",
    "kotlin\tkotlin\t$X.area()\tKotlin method calls\t",
    "csharp\tcsharp\tDebug.Log($X)\tC# (Unity) calls\t",
    "csharp\tcsharp\tnew Vector3($$$A)\tC# object creation\t",
    "lua\tlua\t$O:hit($D)\tLua method calls\t",
    "lua\tlua\tfunction $F($$$A) $$$B end\ta whole Lua function\t",
    "php\tphp\tarray_slice($$$A)\tPHP calls\t",
    "php\tphp\techo $X;\tPHP statements with PHP variables around\t",
    "glsl\t\ttexture($S, $UV)\tGLSL sampling\tlit.frag:7:17",
    "hlsl\t\t$T.Sample($S, $UV)\tHLSL sampling\tlit.hlsl:6:19",
    "wgsl\t\ttextureSample($T, $S, $UV)\tWGSL sampling\tlit.wgsl:6:16",
    "gdscript\t\tprint($$$A)\tGDScript calls\tplayer.gd:13:2",
    "kotlin\tkotlin\tfun $F($$$P): $T = $E\texpression-bodied functions\t",
    "kotlin\tkotlin\t$X!!\tnon-null assertions\t",
    "kotlin\tkotlin\tclass $C($$$P) : $S { $$$B }\ta class body the grammar parses as another kind\t",
    "kotlin\tkotlin\toverride fun $F(): Double = $E\tmodifiers in the pattern\t",
    "cuda\t\t$K<<<$$$L>>>($$$A)\tCUDA kernel launches\tvec.cu:14:5,vec.cu:18:5",
];

// Whether a path has an ending of this language (the TypeScript's EXT table).
fn st_ext(lang: const u8[:], p: const u8[:]) -> bool {
    if lang == "typescript" { return ends_with(p, ".ts") || ends_with(p, ".mts") || ends_with(p, ".cts"); }
    if lang == "kotlin" { return ends_with(p, ".kt") || ends_with(p, ".kts"); }
    if lang == "csharp" { return ends_with(p, ".cs"); }
    if lang == "lua" { return ends_with(p, ".lua"); }
    if lang == "php" { return ends_with(p, ".php"); }
    if lang == "glsl" { return ends_with(p, ".glsl") || ends_with(p, ".vert") || ends_with(p, ".frag") || ends_with(p, ".comp"); }
    if lang == "hlsl" { return ends_with(p, ".hlsl") || ends_with(p, ".hlsli") || ends_with(p, ".fx"); }
    if lang == "wgsl" { return ends_with(p, ".wgsl"); }
    if lang == "gdscript" { return ends_with(p, ".gd"); }
    if lang == "python" { return ends_with(p, ".py") || ends_with(p, ".pyi"); }
    if lang == "rust" { return ends_with(p, ".rs"); }
    if lang == "java" { return ends_with(p, ".java"); }
    if lang == "c" { return ends_with(p, ".c") || ends_with(p, ".h"); }
    if lang == "cuda" { return ends_with(p, ".cu") || ends_with(p, ".cuh"); }
    return false;
}

// Swan's pinned ast-grep (a dev dependency in tools/), else one on PATH.
fn st_ast_grep() -> u8[>..] {
    var cwd: u8[>..] = [];
    var e: u8[>..] = [];
    run(argv(["realpath", "."]), "", cwd, e);
    let here = trim(cwd);
    var p: u8[>..] = [];
    for rel in ["/tools/node_modules/@ast-grep/cli-linux-x64-gnu/ast-grep", "/tools/node_modules/.bin/ast-grep"] {
        if p.len == 0 && file_exists(str(here, rel)) { p.append(str(here, rel)); }
    }
    if p.len == 0 { p.append("ast-grep"); }
    return p;
}

// Lines of a not in b (by line).
fn st_minus(a: const u8[:], b: const u8[:], out: u8[>..]&) -> i64 {
    var in_b = dictionary<u64, bool> {};
    each_split(b, '\n') { l => if l.len > 0 { in_b.insert(hash(l), true); } };
    var n = 0;
    each_split(a, '\n') { l => if l.len > 0 && !in_b.contains(hash(l)) { format(out, l, "\n"); n++; } };
    return n;
}
fn st_dedup(list: const u8[:]) -> u8[>..] {
    var seen = dictionary<u64, bool> {};
    var out: u8[>..] = [];
    each_split(list, '\n') { l => if l.len > 0 && !seen.contains(hash(l)) { seen.insert(hash(l), true); format(out, l, "\n"); } };
    return out;
}
fn st_count(list: const u8[:]) -> i64 { var n = 0; for c in list { if c == '\n' { n++; } } return n; }

fn st_compare(db: const u8[:], root: const u8[:], rel: const u8[:], label: const u8[:], ag: const u8[:]) {
    for cs in ST_CASES {
        var cl: u8[>..] = [];
        cl.append(cs);
        let f = split(cl, '\t');
        let lang = f[0]; let sg = f[1]; let pattern = f[2]; let covers = f[3]; let expect = f[4];
        var qa: u8[>..] = [];
        a1(qa, "bin/swan"); a1(qa, "query"); a1(qa, db); a1(qa, "pattern"); a1(qa, pattern);
        if rel.len > 0 { a1(qa, rel); }
        var so: u8[>..] = [];
        var se: u8[>..] = [];
        if run(qa, "", so, se) != 0 { check(str(label, " ", lang, " ", pattern, ": swan ran"), false, se); continue; }
        var d: json::Node[>..] = []; var x: u8[>..] = [];
        let body, e = json::parse(so, d, x);
        var ours_raw: u8[>..] = [];
        let ms = json::member(body, "matches");
        if ms { json::each(ms) { m => if st_ext(lang, jstr(m, "relative_path")) { format(ours_raw, jstr(m, "relative_path"), ":", jint(m, "line"), ":", jint(m, "column"), "\n"); } }; }
        let ours = st_dedup(ours_raw);
        let n_ours = st_count(ours);
        if expect.len > 0 {
            // Checked only where its files are (the fixture it was written for).
            var all_there = true;
            each_split(expect, ',') { ex => if !file_exists(str(root, "/", ex[..find(ex, ":")])) { all_there = false; } };
            if !all_there { continue; }
            let got = sorted_join(ours);
            check(str(label, " ", lang, " ", pattern, " (", covers, "): ", n_ours, ", by hand"), got == expect, got);
            continue;
        }
        var ga: u8[>..] = [];
        a1(ga, ag); a1(ga, "run"); a1(ga, "-p"); a1(ga, pattern); a1(ga, "-l"); a1(ga, sg); a1(ga, "--json=compact");
        a1(ga, if rel.len > 0 { rel } else { "." });
        var go: u8[>..] = [];
        var ge: u8[>..] = [];
        run_at(ga, root, "", go, ge);
        var d2: json::Node[>..] = []; var x2: u8[>..] = [];
        let gl, e2 = json::parse(if go.len > 0 { go[..] } else { "[]" }, d2, x2);
        var theirs_raw: u8[>..] = [];
        if gl {
            json::each(gl) { m =>
                let file = jstr(m, "file");
                if st_ext(lang, file) {
                    let start = json::member(json::member(m, "range"), "start");
                    let fname = if starts_with(file, "./") { file[2..] } else { file };
                    if rel.len > 0 && !starts_with(file, rel) { format(theirs_raw, rel, "/"); }
                    format(theirs_raw, fname, ":", jint(start, "line") + 1, ":", jint(start, "column") + 1, "\n");
                }
            };
        }
        let theirs = st_dedup(theirs_raw);
        let n_theirs = st_count(theirs);
        if n_ours == 0 && n_theirs == 0 { continue; }   // nothing in this language here
        // ast-grep's own walk skips what .gitignore names, tracked or not;
        // Swan reads those files too. Those are not matching differences.
        var only_us_raw: u8[>..] = [];
        st_minus(ours, theirs, only_us_raw);
        var only_us: u8[>..] = [];
        var n_us = 0;
        each_split(only_us_raw, '\n') { l =>
            guard l.len > 0;
            var io: u8[>..] = [];
            var ie: u8[>..] = [];
            let ignored = run_at(argv(["git", "check-ignore", "-q", "--no-index", l[..find(l, ":")]]), root, "", io, ie) == 0;
            if !ignored { format(only_us, l, " "); n_us++; }
        };
        var only_them: u8[>..] = [];
        let n_them = st_minus(theirs, ours, only_them);
        check(str(label, " ", lang, " ", pattern, " (", covers, "): ", n_ours, " = ast-grep ", n_theirs),
              n_us == 0 && n_them == 0, str("onlyUs: ", only_us, " onlyThem: ", only_them));
    }
}

fn structural_suite() {
    let ag = st_ast_grep();
    var ext_db: u8[>..] = [];
    if env("SWAN_CHECK_DB", ext_db) && ext_db.len > 0 {
        var rel: u8[>..] = [];
        env("SWAN_CHECK_REL", rel);
        let t = swan_query(ext_db, "info", "x", "");
        var d: json::Node[>..] = []; var x: u8[>..] = [];
        let info, e = json::parse(t, d, x);
        st_compare(ext_db, jstr(info, "root"), rel, "repo", ag);
        return;
    }
    let fixtures = ["tiny-ts\tdata/tiny-ts", "tiny-py\tdata/struct/py", "tiny-rs\tdata/struct/rs", "tiny-java\tdata/struct/java",
                    "tiny-cuda\tdata/struct/cuda", "tiny-kt\tdata/struct/kt", "tiny-lua\tdata/struct/lua",
                    "tiny-shaders\tdata/struct/shaders", "tiny-game\tdata/struct/game"];
    for pair in fixtures {
        var pl: u8[>..] = [];
        pl.append(pair);
        let p = split(pl, '\t');
        let fx = p[0];
        let map = p[1];
        let root = if fx == "tiny-kt" { str(map, "-repo") } else { str("fixtures/", fx) };
        if fx != "tiny-ts" {
            // Kotlin's map runs a Gradle build, which writes into the repo: map a copy.
            if fx == "tiny-kt" {
                rm_rf(root);
                mkdir_p("data/struct");
                var o: u8[>..] = [];
                var e: u8[>..] = [];
                run(argv(["cp", "-r", str("fixtures/", fx), root]), "", o, e);
            }
            var mo: u8[>..] = [];
            var me: u8[>..] = [];
            if run(argv(["bin/swan", "map", root, map]), "", mo, me) != 0 { check(str("map ", fx), false, me[max(0, me.len - 400)..]); continue; }
        }
        st_compare(str(map, "/swan.db"), root, "", fx, ag);
    }
    st_rewrites();
}

fn st_rewrites() {
    // Rewrite on a scratch copy: plan, apply, and the stale refusal.
    rm_rf("data/struct/rw");
    mkdir_p("data/struct/rw");
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", "fixtures/tiny-rs", "data/struct/rw/repo"]), "", o) else { return; }
    var me: u8[>..] = [];
    run(argv(["bin/swan", "map", "data/struct/rw/repo", "data/struct/rw/out"]), "", o, me);
    guard mcp_open(argv(["bin/swan", "serve", "data/struct/rw/out/swan.db"]), "") else { return; }
    let lib = "data/struct/rw/repo/src/lib.rs";
    var before: u8[>..] = [];
    read_file(lib, before);
    var t: u8[>..] = [];
    var now: u8[>..] = [];

    mcp_call("search_pattern", """{"pattern":"self.$F * self.$F"}""", t);
    var d1: json::Node[>..] = []; var x1: u8[>..] = [];
    let hit, e1 = json::parse(t, d1, x1);
    let m0 = nth(json::member(hit, "matches"), 0);
    check("search_pattern ties a match to its symbol: Tile/area",
          jcount(json::member(hit, "matches")) == 1 && jstr(m0, "in_symbol") == "Tile/area" && jstr(json::member(m0, "captures"), "F") == "side", t);

    mcp_call("rewrite_pattern", """{"pattern":"self.$F * self.$F","rewrite":"self.$F.pow(2)"}""", t);
    var d2: json::Node[>..] = []; var x2: u8[>..] = [];
    let plan, e2 = json::parse(t, d2, x2);
    let ap, apok = json::as_bool(json::member(plan, "applied"));
    now.clear(); read_file(lib, now);
    check("rewrite_pattern plans without writing",
          apok && !ap && jstr(nth(json::member(plan, "edits"), 0), "after") == "self.side.pow(2)" && now == before, t);

    let dok = mcp_call("rewrite_pattern", """{"pattern":"self.$F * self.$F","rewrite":"self.$F.pow(2)","apply":true}""", t) == 1;
    var d3: json::Node[>..] = []; var x3: u8[>..] = [];
    let done, e3 = json::parse(t, d3, x3);
    now.clear(); read_file(lib, now);
    check("apply writes it", dok && jint(done, "files_written") == 1 && find(now, "self.side.pow(2)") >= 0, t);

    // A rewrite that adds lines moves the map with it: a symbol edit after
    // it still lands where the symbol is now, not three lines up.
    var tg: u8[>..] = [];
    var tm: u8[>..] = [];
    let gok = mcp_call("rewrite_pattern", """{"pattern":"3 * self.$F * self.$F","rewrite":"{\n            let r = self.$F;\n            3 * r * r\n        }","apply":true}""", tg) == 1;
    let mok = mcp_call("insert_before_symbol", """{"name_path":"first_is_square","relative_path":"src/lib.rs","body":"pub fn marker() -> u32 {\n    7\n}"}""", tm) == 1;
    now.clear(); read_file(lib, now);
    check("after a rewrite that adds lines, an edit by symbol lands at the symbol",
          gok && mok && find(now, "pub fn marker() -> u32 {\n    7\n}\n\npub fn first_is_square()") >= 0, str(tg, "\n     ", tm));

    var tweaked: u8[>..] = [];
    let at = find(before, "pub side: u32");
    tweaked.append(before[..at]); tweaked.append("pub side:  u32"); tweaked.append(before[at + 13..]);
    write_file(lib, tweaked);
    let rok = mcp_call("rewrite_pattern", """{"pattern":"3 * self.$F * self.$F","rewrite":"3 * self.$F.pow(2)","apply":true}""", t);
    var d4: json::Node[>..] = []; var x4: u8[>..] = [];
    let refused, e4 = json::parse(t, d4, x4);
    check("a file changed outside Swan since the map is refused", rok == 0 && find(jstr(refused, "refused"), "refresh first") >= 0, t);
    mcp_close();

    // Search-only languages (Lua here) have no rows: a second rewrite of the
    // same file must still be Swan's own edit, not an outside change.
    rm_rf("data/struct/rw-lua");
    mkdir_p("data/struct/rw-lua");
    if sh(argv(["cp", "-r", "fixtures/tiny-lua", "data/struct/rw-lua/repo"]), "", o) {
        run(argv(["bin/swan", "map", "data/struct/rw-lua/repo", "data/struct/rw-lua/out"]), "", o, me);
        if mcp_open(argv(["bin/swan", "serve", "data/struct/rw-lua/out/swan.db"]), "") {
            var t1: u8[>..] = [];
            var t2: u8[>..] = [];
            let ok1 = mcp_call("rewrite_pattern", """{"pattern":"print($X)","rewrite":"log_line($X)","apply":true}""", t1) == 1;
            let ok2 = mcp_call("rewrite_pattern", """{"pattern":"log_line($X)","rewrite":"print($X)","apply":true}""", t2) == 1;
            var d5: json::Node[>..] = []; var x5: u8[>..] = [];
            let twice, e5 = json::parse(t2, d5, x5);
            var a: u8[>..] = [];
            var b: u8[>..] = [];
            read_file("data/struct/rw-lua/repo/game.lua", a);
            read_file("fixtures/tiny-lua/game.lua", b);
            check("a Lua file can be rewritten twice in a row", ok1 && ok2 && jtrue(twice, "applied") && a == b, str(t1, "\n     ", t2));
            mcp_close();
        }
    }

    // A repo of only geometry and effect shaders still maps.
    rm_rf("data/struct/geom");
    mkdir_p("data/struct/geom/repo");
    run(argv(["cp", "fixtures/tiny-shaders/lit.frag", "data/struct/geom/repo/only.geom"]), "", o, me);
    write_file("data/struct/geom/repo/only.fx", "float4 main() : SV_Target { return 1; }\n");
    var gout: u8[>..] = [];
    var gerr: u8[>..] = [];
    let gc = run(argv(["bin/swan", "map", "data/struct/geom/repo", "data/struct/geom/out"]), "", gout, gerr);
    check("a repo of .geom and .fx shaders maps", gc == 0, str(gout, gerr));

    // Back on the Rust map: a pattern that does not parse says so.
    guard mcp_open(argv(["bin/swan", "serve", "data/struct/rw/out/swan.db"]), "") else { return; }
    mcp_call("search_pattern", """{"pattern":"fn (((","language":"rust"}""", t);
    var d6: json::Node[>..] = []; var x6: u8[>..] = [];
    let bad, e6 = json::parse(t, d6, x6);
    check("a pattern that does not parse says so", jcount(json::member(bad, "pattern_does_not_parse_in")) == 1, t);
    mcp_close();
}
