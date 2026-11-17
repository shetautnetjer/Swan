// Live errors from the language servers added for game and 3D code: Lua
// (lua-language-server), the GLSL, HLSL and WGSL shaders (shader-validator's
// server), C++ (clangd), C# (csharp-ls) and Blender Python (pyright with
// Blender's stubs). Each fixture is mapped from a copy, checked clean, given
// a deliberate error, checked again, and put back. For C#, the full map from
// scip-dotnet is checked too. (Was tests/game_live_check.ts.)

import std;
import os;
import json;
import .harness;

// The error-severity diagnostics of an answer that may not be JSON at all
// (then none): their count, and ",line," for each in lines.
fn gl_errors(text: const u8[:], lines: u8[>..]&) -> i64 {
    var d: json::Node[>..] = []; var x: u8[>..] = [];
    let r, e = json::parse(text, d, x);
    var n = 0;
    lines.clear();
    let ds = json::member(r, "diagnostics");
    if ds { json::each(ds) { g => if jstr(g, "severity") == "error" { n++; format(lines, ",", jint(g, "line"), ","); } }; }
    return n;
}

// One fixture: copy it (from `from`), map it, serve it, and for each case
// check the file clean, with the deliberate error (want_line 0: any error;
// else an error on that line) and after the undo. Cases are parallel lists,
// one per line in each.
fn gl_session(fixture: const u8[:], from: const u8[:], files: const u8[:], labels: const u8[:],
              olds: const u8[:], news: const u8[:], want_lines: const i64[:], prepare_db: bool) {
    let dir = str("data/game-live/", fixture);
    rm_rf(dir);
    mkdir_p(dir);
    var o: u8[>..] = [];
    guard sh(argv(["cp", "-r", from, str(dir, "/repo")]), "", o) else { return; }
    if prepare_db {
        // The repo's own compile_commands.json, which defines SCORE_BONUS.
        var cwd: u8[>..] = [];
        var e: u8[>..] = [];
        run(argv(["realpath", "."]), "", cwd, e);
        var cdb: u8[>..] = [];
        cdb.push('[');
        var first = true;
        for f in ["main.cpp", "score.cpp", "bonus.cpp"] {
            if !first { cdb.push(','); }
            first = false;
            format(cdb, "{\"directory\":\"", trim(cwd), "/", dir, "/repo/src\",\"file\":\"", f,
                   "\",\"arguments\":[\"clang++\",\"-DSCORE_BONUS=5\",\"-c\",\"", f, "\"]}");
        }
        cdb.push(']');
        write_file(str(dir, "/repo/compile_commands.json"), cdb);
    }
    var mout: u8[>..] = [];
    var merr: u8[>..] = [];
    if run(argv(["bin/swan", "map", str(dir, "/repo"), str(dir, "/out")]), "", mout, merr) != 0 {
        check(str(fixture, ": swan map"), false, str(mout, merr));
        return;
    }
    guard mcp_open(argv(["bin/swan", "serve", str(dir, "/out/swan.db")]), "") else { return; }
    var fl: u8[>..] = []; fl.append(files);
    var ll: u8[>..] = []; ll.append(labels);
    var ol: u8[>..] = []; ol.append(olds);
    var nl: u8[>..] = []; nl.append(news);
    let fs = split(fl, '\n');
    let ls = split(ll, '\n');
    let os_ = split(ol, '\n');
    let ns = split(nl, '\n');
    var lines: u8[>..] = [];
    for k in want_lines.len {
        let path = str(dir, "/repo/", fs[k]);
        var orig: u8[>..] = [];
        read_file(path, orig);
        let args = str("{\"relative_path\":\"", fs[k], "\",\"live\":true}");
        var clean: u8[>..] = [];
        let t0 = clock();
        let ok1 = mcp_call("get_diagnostics", args, clean) == 1;
        let ms1 = ((clock() - t0) * 1000.0) as i64;
        let n_clean = gl_errors(clean, lines);
        check(str(ls[k], ": the clean file has no errors (", ms1, " ms)"), ok1 && n_clean == 0, clean);
        replace_in_file(path, os_[k], ns[k]);
        var broken: u8[>..] = [];
        let t1 = clock();
        let ok2 = mcp_call("get_diagnostics", args, broken) == 1;
        let ms2 = ((clock() - t1) * 1000.0) as i64;
        let n = gl_errors(broken, lines);
        let wanted = if want_lines[k] == 0 { n > 0 } else { find(lines, str(",", want_lines[k], ",")) >= 0 };
        check(str(ls[k], ": the deliberate error is reported (", ms2, " ms)"), ok2 && wanted, broken);
        write_file(path, orig);
        var fixed: u8[>..] = [];
        let ok3 = mcp_call("get_diagnostics", args, fixed) == 1;
        let n_fixed = gl_errors(fixed, lines);
        check(str(ls[k], ": gone after the undo"), ok3 && n_fixed == 0, fixed);
    }
    let code = mcp_close_code();
    check(str(fixture, ": serve exits cleanly"), code == 0, str("exit ", code));
}

fn game_suite() {
    if exists(".tools/lua-ls") {
        gl_session("tiny-lua", "fixtures/tiny-lua", "game.lua", "Lua", "hero:hit(10)", "hero:hit(10", [0], false);
    } else { print("skipped Lua: no .tools/lua-ls"); }
    if exists(".tools/shader-ls") {
        gl_session("tiny-shaders", "fixtures/tiny-shaders", "lit.frag\nlit.hlsl\nlit.wgsl", "GLSL\nHLSL\nWGSL",
                   "color = vec4(\nreturn float4(\nlet base =", "color = vec3(\nreturn undefinedThing(\nlet base: i32 =", [0, 0, 0], false);
    } else { print("skipped shaders: no .tools/shader-ls"); }
    if exists(".tools/clangd") {
        gl_session("tiny-cpp", "fixtures/tiny-cpp", "src/main.cpp", "C++", "add_points(score, 10)", "add_points(score)", [5], false);
        // A repo with its own compile_commands.json: clangd must use it
        // (here it defines SCORE_BONUS, which the code needs).
        let src = "data/game-live/cpp-own-db-src";
        rm_rf(src);
        mkdir_p("data/game-live");
        var o: u8[>..] = [];
        if sh(argv(["cp", "-r", "fixtures/tiny-cpp", src]), "", o) {
            write_file(str(src, "/src/bonus.cpp"), "int bonus() { return SCORE_BONUS; }\n");
            gl_session("cpp-own-db", src, "src/bonus.cpp", "C++ with the repo's own compile_commands.json",
                       "SCORE_BONUS", "SCORE_BONUS + missing_name", [1], true);
        }
    } else { print("skipped C++: no .tools/clangd"); }
    if exists(".tools/dotnet-tools/csharp-ls") && exists(".tools/dotnet-tools/scip-dotnet") {
        gl_session("tiny-cs", "fixtures/tiny-cs", "src/Program.cs", "C#", "Combat.Strike(hero, 10)", "Combat.Strike(hero)", [4], false);
        // The full map from scip-dotnet: implementations of an interface and
        // callers of a method, with no obj/ files in it.
        let db = "data/game-live/tiny-cs/out/swan.db";
        var t = swan_query(db, "impls", "IDamageable", "");
        var d1: json::Node[>..] = []; var x1: u8[>..] = [];
        let r1, e1 = json::parse(t, d1, x1);
        check("C# map: Player and Crate implement IDamageable",
              sorted_join(jlist(json::member(r1, "implementations"), "name_path")) == "Crate,Player", t);
        t = swan_query(db, "callers", "Strike", "");
        var d2: json::Node[>..] = []; var x2: u8[>..] = [];
        let r2, e2 = json::parse(t, d2, x2);
        check("C# map: Arena/Round, the expression-bodied Tricks/Finish and Boss's constructor call Combat/Strike",
              sorted_join(jlist(json::member(r2, "callers"), "name_path")) == "Arena/Round,Boss/.ctor,Tricks/Finish", t);
        t = swan_query(db, "overview", "src/Shapes.cs", "");
        var d3: json::Node[>..] = []; var x3: u8[>..] = [];
        let r3, e3 = json::parse(t, d3, x3);
        check("C# map: a lambda in a constructor initializer leaves the constructor's body whole",
              jints(json::member(jfind(r3, "name_path", "Boss/.ctor"), "body_lines")) == "61,65", t);
        check("C# map: a verbatim string ending in \\ and strings holding braces leave the body whole",
              jints(json::member(jfind(r3, "name_path", "Tricks/SavePath"), "body_lines")) == "46,50", t);
        t = swan_query(db, "refs", "Strike", "");
        var d4: json::Node[>..] = []; var x4: u8[>..] = [];
        let r4, e4 = json::parse(t, d4, x4);
        check("C# map: the top-level call in Program.cs is a reference",
              jany(json::member(nth(r4, 0), "references"), "relative_path", "src/Program.cs"), t);
        var occ: u8[>..] = [];
        read_file("data/game-live/tiny-cs/out/occurrences.tsv", occ);
        var obj = false;
        each_split(occ, '\n') { l =>
            let tab = find(l, "\t");
            if tab >= 0 && starts_with(l[tab + 1..], "obj/") { obj = true; }
        };
        check("C# map: no generated obj/ files", !obj, "");
    } else { print("skipped C#: no .tools/dotnet-tools (csharp-ls, scip-dotnet)"); }
    if exists(".tools/blender-stubs") {
        gl_session("tiny-blender", "fixtures/tiny-blender", "addon.py", "Blender Python",
                   "obj.name = prefix + obj.name", "obj.name = 3", [16], false);
    } else { print("skipped Blender: no .tools/blender-stubs"); }
}
