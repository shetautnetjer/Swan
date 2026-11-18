// `swan check`: the repo's own compilers and linters, their output parsed
// into diagnostics rows for the map.

import std;
import os;
import json;
import dictionary;
import sqlite;

// A TSV field: tabs and newlines folded to spaces.
fn put_field(row: u8[>..]&, s: const u8[:]) {
    for c in s { row.push(if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c }); }
}

fn put_row(rows: u8[>..]&, file: const u8[:], l: i64, c: i64, el: i64, ec: i64, sev: const u8[:],
           source: const u8[:], code: const u8[:], msg: const u8[:]) {
    put_field(rows, file);
    format(rows, "\t", l, "\t", c, "\t", el, "\t", ec, "\t");
    put_field(rows, sev);
    rows.push('\t');
    put_field(rows, source);
    rows.push('\t');
    put_field(rows, code);
    rows.push('\t');
    put_field(rows, if msg.len > 500 { msg[..500] } else { msg });
    rows.push('\n');
}

fn relative_to(repo: const u8[:], file: const u8[:]) -> const u8[:] {
    if starts_with(file, repo) && file.len > repo.len && file[repo.len] == '/' { return file[repo.len + 1..]; }
    return file;
}

// tsc --pretty false: `file(line,col): error TS2554: message`
fn parse_tsc(text: const u8[:], rows: u8[>..]&) -> i64 {
    var n = 0;
    each_split(text, '\n') { line =>
        let lp = find(line, "(");
        let rp = find(line, "): ");
        guard lp > 0 && rp > lp;
        let coords = split(line[lp + 1..rp], ',');
        guard coords.len == 2;
        let ln, ok1 = parse_int(coords[0]);
        let cn, ok2 = parse_int(coords[1]);
        guard ok1 && ok2;
        let rest = line[rp + 3..];
        let sp = find(rest, " ");
        let colon = find(rest, ": ");
        guard sp > 0 && colon > sp;
        let sev = rest[..sp];
        put_row(rows, line[..lp], ln - 1, cn - 1, ln - 1, cn - 1, if sev == "message" { "info" } else { sev },
                "tsc", rest[sp + 1..colon], rest[colon + 2..]);
        n++;
    };
    return n;
}

// cargo check --message-format=json: one JSON object per line.
fn parse_cargo(text: const u8[:], repo: const u8[:], rows: u8[>..]&, source: const u8[:] = "cargo") -> i64 {
    var n = 0;
    each_split(text, '\n') { line =>
        guard line.len > 0 && line[0] == '{';
        var doc: json::Node[>..] = [];
        var decoded: u8[>..] = [];
        let root, perr = json::parse(line, doc, decoded);
        guard root;
        let reason, r_ok = json::as_string(json::member(root, "reason"));
        guard r_ok && reason == "compiler-message";
        let msg = json::member(root, "message");
        let level, l_ok = json::as_string(json::member(msg, "level"));
        guard l_ok && (level == "error" || level == "warning");
        let text_, t_ok = json::as_string(json::member(msg, "message"));
        let code, c_ok = json::as_string(json::member(json::member(msg, "code"), "code"));
        let spans = json::member(msg, "spans");
        guard spans;
        json::each(spans) { sp =>
            let primary, p_ok = json::as_bool(json::member(sp, "is_primary"));
            if p_ok && primary {
                let file, f_ok = json::as_string(json::member(sp, "file_name"));
                let ls, a1 = json::as_i64(json::member(sp, "line_start"));
                let cs, a2 = json::as_i64(json::member(sp, "column_start"));
                let le, a3 = json::as_i64(json::member(sp, "line_end"));
                let ce, a4 = json::as_i64(json::member(sp, "column_end"));
                if f_ok && a1 && a2 && a3 && a4 && (!starts_with(file, "/") || starts_with(file, repo)) {
                    put_row(rows, relative_to(repo, file), ls - 1, cs - 1, le - 1, ce - 1, level, source,
                            if c_ok { code } else { "" }, if t_ok { text_ } else { "" });
                    n++;
                }
            }
        };
        assert(perr.len >= 0);
    };
    return n;
}

// pyright --outputjson: generalDiagnostics with absolute paths.
fn parse_pyright(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let start = find(text, "{");
    guard start >= 0 else { return 0; }
    let root, perr = json::parse(text[start..], doc, decoded);
    guard root else { write_stderr(str("pyright output: ", perr, "\n")); return 0; }
    let list = json::member(root, "generalDiagnostics");
    guard list else { return 0; }
    var n = 0;
    json::each(list) { d =>
        let file, f_ok = json::as_string(json::member(d, "file"));
        let sev, s_ok = json::as_string(json::member(d, "severity"));
        let msg, m_ok = json::as_string(json::member(d, "message"));
        let rule, r_ok = json::as_string(json::member(d, "rule"));
        let range = json::member(d, "range");
        let ls, a1 = json::as_i64(json::member(json::member(range, "start"), "line"));
        let cs, a2 = json::as_i64(json::member(json::member(range, "start"), "character"));
        let le, a3 = json::as_i64(json::member(json::member(range, "end"), "line"));
        let ce, a4 = json::as_i64(json::member(json::member(range, "end"), "character"));
        if f_ok && s_ok && a1 && a2 && a3 && a4 {
            put_row(rows, relative_to(repo, file), ls, cs, le, ce,
                    if sev == "information" { "info" } else { sev }, "pyright",
                    if r_ok { rule } else { "" }, if m_ok { msg } else { "" });
            n++;
        }
    };
    return n;
}

// javac: `path:line: error: message`, then the source line, then a caret
// under the column.
fn parse_javac(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    let lines = split(text, '\n');
    var n = 0;
    for line, i in lines {
        let j = find(line, ".java:");
        guard j > 0 else { continue; }
        let rest = line[j + 6..];
        let colon = find(rest, ": ");
        guard colon > 0 else { continue; }
        let ln, ok = parse_int(rest[..colon]);
        guard ok else { continue; }
        let tail = rest[colon + 2..];
        let sev_end = find(tail, ": ");
        guard sev_end > 0 else { continue; }
        let sev = tail[..sev_end];
        guard sev == "error" || sev == "warning" else { continue; }
        var col = 0;
        if i + 2 < lines.len {
            let caret = find(lines[i + 2], "^");
            if caret >= 0 { col = caret; }
        }
        put_row(rows, relative_to(repo, line[..j + 5]), ln - 1, col, ln - 1, col, sev, "javac", "",
                tail[sev_end + 2..]);
        n++;
    }
    return n;
}

// clang: `path:line:col: error: message` (it prints each diagnostic once per
// compilation side, host and device, so repeats are dropped).
fn parse_clang(text: const u8[:], repo: const u8[:], rows: u8[>..]&) -> i64 {
    var n = 0;
    var seen = dictionary<const u8[:], bool> {};
    each_split(text, '\n') { line =>
        guard starts_with(line, "/") && !seen.contains(line);
        let parts = split(line, ':');
        guard parts.len >= 5;
        let ln, ok1 = parse_int(parts[1]);
        let cn, ok2 = parse_int(parts[2]);
        guard ok1 && ok2;
        let sev = trim(parts[3]);
        guard sev == "error" || sev == "warning" || sev == "fatal error";
        seen.insert(line, true);
        let msg_at = find(line, str(parts[3], ":")) + parts[3].len + 1;
        put_row(rows, relative_to(repo, parts[0]), ln - 1, cn - 1, ln - 1, cn - 1,
                if sev == "warning" { "warning" } else { "error" }, "clang", "", trim(line[msg_at..]));
        n++;
    };
    return n;
}

fn check_main(repo_arg: const u8[:], out_arg: const u8[:], report: u8[>..]&) -> bool {
    let repo = abs_path(repo_arg);
    let out = abs_path(out_arg);
    let db = str(out, "/swan.db");
    guard file_exists(db) else { format(report, "no map at ", db, "; run swan map first"); return false; }
    let home = swan_home();
    let bin = str(home, "/tools/node_modules/.bin/");
    walk_ignore_load(repo, out);
    var l = detect(repo);
    var rows: u8[>..] = [];
    var ran: u8[>..] = [];
    let trusted = build_trusted(repo, out);
    if !trusted { l.venv.clear(); }     // the repo's virtualenv is its own code (see map_main)
    var skipped: u8[>..] = [];
    // Checkers that never got to check: not started (126, 127), timed out
    // (-2), killed, or failed with nothing to show for it (a checker that
    // found errors says which). Cargo says itself whether the build ran to
    // its end ("build-finished"); one that stopped early (a dependency that
    // will not resolve, a build script that failed) checked only part of
    // the code, whatever it printed. Their silence is not a clean bill, so
    // the diagnostics already saved are kept rather than replaced by a
    // partial set.
    var not_run: u8[>..] = [];
    fn cargo_finished(output: const u8[:]) -> bool { return find(output, "\"reason\":\"build-finished\"") >= 0; }
    fn checked(name: const u8[:], code: i64, found: i64, finished: bool = true) -> bool {
        let broke = code < 0 || code == 126 || code == 127 || code >= 128 || (code != 0 && !finished);
        guard broke || (code != 0 && found == 0) else { return true; }
        format(not_run, " ", name, if code == -2 { str(" (timed out)") }
                                    else if broke { str(" (exit ", code, ")") }
                                    else { str(" (exit ", code, " and no findings)") });
        return false;
    }

    // Only with the repo's own tsconfig: the one Swan generates to index a
    // repo without one has no say over how strict its code means to be.
    if l.tsconfig {
        var a: u8[>..] = [];
        arg(a, str(bin, "tsc"));
        arg(a, "--noEmit");
        arg(a, "--pretty");
        arg(a, "false");
        arg(a, "-p");
        arg(a, repo);
        var o: u8[>..] = [];
        let code = run_step("tsc", a, repo, child_env(l, ""), 1800000, o);   // exit 2 when it finds errors
        let n = parse_tsc(o, rows);
        if checked("tsc", code, n) { format(ran, " tsc:", n); }
    }
    if l.cargo && !trusted {
        skipped.append(" cargo check and clippy (Rust build scripts, proc macros)");
    } else if l.cargo {
        var a: u8[>..] = [];
        arg(a, "cargo");
        arg(a, "check");
        arg(a, "--workspace");
        arg(a, "--all-targets");
        arg(a, "--message-format=json");
        arg(a, "--keep-going");     // every crate it can check, not just up to the first that fails
        arg(a, "--quiet");
        var o: u8[>..] = [];
        let extra = env_entry("CARGO_TARGET_DIR", str(out, "/cargo-target"));
        let code = run_step("cargo check", a, repo, child_env(l, extra), 3600000, o);
        let n = parse_cargo(o, repo, rows);
        if checked("cargo", code, n, cargo_finished(o)) { format(ran, " cargo:", n); }
    }
    if l.py {
        // pyright run from the repo root reads the repo's own settings
        // (pyrightconfig.json, pyproject.toml) if it has any; --pythonpath points it
        // at the repo's interpreter, so installed packages resolve.
        var py: u8[>..] = [];
        if l.venv.len > 0 { format(py, l.venv, "/bin/python"); }
        else {
            var which: u8[>..] = [];
            arg(which, "python3");
            arg(which, "-c");
            arg(which, "import sys; print(sys.executable, end='')");
            var e: u8[>..] = [];
            swan_run(which, repo, child_env(l, ""), 30000, py, e);
        }
        var a: u8[>..] = [];
        arg(a, str(bin, "pyright"));
        arg(a, "--outputjson");
        arg(a, "--pythonpath");
        arg(a, py);
        var o: u8[>..] = [];
        let code = run_step("pyright", a, repo, child_env(l, ""), 3600000, o);   // exit 1 when it finds errors
        let n = parse_pyright(o, repo, rows);
        if checked("pyright", code, n) { format(ran, " pyright:", n); }
    }
    if l.java && !l.maven && !l.gradle {
        // javac over every source, output thrown away in out-dir.
        var files: u8[>..] = [];
        each_file(repo) { full, name => if ends_with(name, ".java") { files.append(full); files.push('\n'); } };
        write_file(str(out, "/javac-files.txt"), files);
        var a: u8[>..] = [];
        let jh = java_home(home);
        let javac: u8[>..] = if jh.len > 0 { str(jh, "/bin/javac") } else { str("javac") };
        arg(a, javac);
        arg(a, "-d");
        arg(a, str(out, "/javac-classes"));
        arg(a, "-encoding");
        arg(a, "UTF-8");
        arg(a, "-proc:none");
        arg(a, "-Xmaxerrs");
        arg(a, "100000");
        arg(a, str("@", out, "/javac-files.txt"));
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        let t0 = clock();
        let code = swan_run(a, repo, child_env(l, ""), 1800000, o, e);   // javac reports on stderr
        write_stderr(str("javac: ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
        let n = parse_javac(e, repo, rows);
        if checked("javac", code, n) { format(ran, " javac:", n); }
    } else if l.java {
        format(ran, " javac: skipped (Maven/Gradle repo; its build tool is not run yet)");
    }
    if l.c || l.cuda {
        // No nvcc needed: clang's own frontend, as scip-clang runs it, reports
        // the errors (CUDA in host mode), from the same compile commands.
        var compdb: u8[>..] = [];
        if file_exists(str(repo, "/compile_commands.json")) { format(compdb, repo, "/compile_commands.json"); }
        else if file_exists(str(repo, "/build/compile_commands.json")) { format(compdb, repo, "/build/compile_commands.json"); }
        else {
            format(compdb, out, "/compile_commands.json");
            write_compdb(repo, home, compdb);
        }
        var a: u8[>..] = [];
        arg(a, str(home, "/.tools/scip-clang/scip-clang"));
        arg(a, "--show-compiler-diagnostics");
        arg(a, str("--compdb-path=", compdb));
        arg(a, str("--index-output-path=", out, "/check-cxx.scip"));
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        let t0 = clock();
        let code = swan_run(a, repo, child_env(l, ""), 3600000, o, e);
        write_stderr(str("clang (via scip-clang): ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
        let n = parse_clang(e, repo, rows);
        if checked("clang", code, n) { format(ran, " clang:", n); }
    }
    // Linters, from tools/modules.json.
    let mc = mod_ctx(repo, out, home, l);
    each_split(module_langs(l), '\n') { lang =>
        guard lang.len > 0;
        var o: u8[>..] = [];
        var src: u8[>..] = [];
        var par: u8[>..] = [];
        let code = run_module(home, lang, "lint", mc, child_env(l, ""), "", o, src, par);
        if code != -100 {
            let n = if par == "github" { parse_github(o, repo, src, rows) }
                    else if par == "cargo" { parse_cargo(o, repo, rows, src) } else { 0 };
            if checked(lang, code, n, par != "cargo" || cargo_finished(o)) { format(ran, " ", src, ":", n); }
        }
    };
    guard not_run.len == 0 else {
        format(report, "could not check:", not_run, "; the saved diagnostics are unchanged", if ran.len > 0 { str(" (ran", ran, ")") } else { str("") });
        return false;
    }
    if skipped.len > 0 {
        format(report, untrusted_note(skipped, repo), "\n");
        // Rust went unchecked: its saved diagnostics stay as they were.
        var prev: u8[>..] = [];
        read_file(str(out, "/diagnostics.tsv"), prev);
        each_split(prev, '\n') { line =>
            let f = split(line, '\t');
            if f.len > 6 && (f[6] == "cargo" || f[6] == "clippy") { format(rows, line, "\n"); }
        };
    }
    guard ran.len > 0 else { format(report, "no checker for the languages in ", repo); return false; }
    write_file(str(out, "/diagnostics.tsv"), rows);
    format(report, "checked", ran, "\n");
    diagnostics_main(out, db, report);
    return true;
}
