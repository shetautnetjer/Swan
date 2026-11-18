// The survey of a repo's projects, from Spread-Wings.
//
// `spread-wings survey <repo>` reads manifest, lock and version files and
// lists the projects a repo holds: where each is, its package manager, the
// versions it wants, its workspace, whether its dependencies are installed
// (docs/wings-and-swan.md: what can be learned by only reading files is
// Spread-Wings' to find). Swan runs it first in every map, sealed, keeps the
// answer as survey.json in the map folder, says in the report what the repo
// holds, and uses it where it used to assume one project at the top:
//
//   Go     the language server is started in each module's own folder. From
//          the top of a repo whose go.mod files are further down, gopls
//          took 50 s for relatedb/relate's 38 Go files (2026-11-18); from
//          the module that holds 27 of them, 6 s, with the same rows.
//
//   Python a project's own virtualenv is read, not run, for the packages
//          it holds and the Python it was made with, wherever the project
//          is (src/pipeline.goose, the Python step). Swan looked only at
//          the top of the repo, and used what it found only once the repo
//          was trusted.
//
// Without Spread-Wings, or when the survey fails, a map goes on as before
// and says so.

import std;
import os;
import json;

// Runs the survey and keeps it as <out>/survey.json. The JSON text, or ""
// with the reason in `why`.
fn survey_run(repo: const u8[:], out: const u8[:], why: u8[>..]&) -> u8[>..] {
    var text: u8[>..] = [];
    let bin = wings_bin(why);
    guard bin.len > 0 else { return text; }
    // Absolute: the sealed run starts in the repo, not where Swan was started.
    var dir: u8[>..] = [];
    guard swan_realpath(out, dir) else { format(why, "cannot find the map folder ", out); return text; }
    var a: u8[>..] = [];
    arg(a, bin); arg(a, "survey"); arg(a, repo);
    var e: u8[>..] = [];
    let code = sealed_run(a, repo, dir, false, "", 60000, text, e);
    guard code == 0 && text.len > 0 && text[0] == '{' else {
        // An older Spread-Wings answers an unknown command with its usage.
        if find(text, "spread-wings index <repo>") >= 0 || find(e, "spread-wings index <repo>") >= 0 {
            why.append("this spread-wings has no survey command (it is older than ececa28)");
        } else {
            let tail = if e.len > 200 { e[e.len - 200..] } else { e[..] };
            format(why, "spread-wings survey failed (exit ", code, "): ", trim(tail));
        }
        text.clear();
        return text;
    }
    write_file(str(dir, "/survey.json"), text);
    return text;
}

// The folders git ignores, as the map keeps them (git-ignored-all.txt, one
// per line). The survey reads no .gitignore, so it lists a project in such
// a folder; the map leaves the folder out, and so does everything here.
fn survey_ignored(out: const u8[:]) -> u8[>..] {
    var list: u8[>..] = [];
    read_file(str(out, "/git-ignored-all.txt"), list);
    return list;
}

fn in_ignored(ignored: const u8[:], path: const u8[:]) -> bool {
    var yes = false;
    each_split(ignored, '\n') { d =>
        if d.len > 0 && (path == d || (path.len > d.len && starts_with(path, d) && path[d.len] == '/')) { yes = true; }
    };
    return yes;
}

// The folders of a survey's projects of one kind, one per line ("." is the
// top of the repo), without those in folders git ignores.
fn survey_paths(survey: const u8[:], kind: const u8[:], ignored: const u8[:]) -> u8[>..] {
    var paths: u8[>..] = [];
    guard survey.len > 0 else { return paths; }
    var text: u8[>..] = [];
    text.append(survey);
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(text, doc, dec);
    let list = json::member(root, "projects");
    guard list else { return paths; }
    json::each(list) { p =>
        let k, k_ok = json::as_string(json::member(p, "kind"));
        let at, at_ok = json::as_string(json::member(p, "path"));
        if k_ok && at_ok && k == kind && !in_ignored(ignored, at) { format(paths, at, "\n"); }
    };
    return paths;
}

// The virtualenvs of a survey's Python projects, one per line, in the
// survey's order (the top of the repo first):
// "<project folder>\t<virtualenv, relative to the repo>\t<its Python>".
// The Python version is what the virtualenv's pyvenv.cfg says ("" when it
// says none). Without the projects in folders git ignores.
fn survey_python_envs(survey: const u8[:], ignored: const u8[:]) -> u8[>..] {
    var envs: u8[>..] = [];
    guard survey.len > 0 else { return envs; }
    var text: u8[>..] = [];
    text.append(survey);
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(text, doc, dec);
    let list = json::member(root, "projects");
    guard list else { return envs; }
    json::each(list) { p =>
        let k, k_ok = json::as_string(json::member(p, "kind"));
        let at, at_ok = json::as_string(json::member(p, "path"));
        let e = json::member(p, "environment");
        let v, v_ok = json::as_string(json::member(e, "venv"));
        let py, py_ok = json::as_string(json::member(e, "python"));
        if k_ok && at_ok && k == "python" && v_ok && v.len > 0 && !in_ignored(ignored, at) {
            format(envs, at, "\t", v, "\t");
            if py_ok { envs.append(trim(py)); }
            envs.push('\n');
        }
    };
    return envs;
}

// What the repo holds, for the map's report: the projects by kind, and the
// node projects whose dependencies are not installed. Projects in folders
// git ignores are not counted.
fn survey_report(survey: const u8[:], ignored: const u8[:], report: u8[>..]&) {
    guard survey.len > 0 else { return; }
    var text: u8[>..] = [];
    text.append(survey);
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(text, doc, dec);
    let list = json::member(root, "projects");
    guard list else { return; }
    var said: u8[>..] = [];
    var total = 0;
    for kind in ["node", "python", "rust", "go", "java", "deno"] {
        var n = 0;
        var managers: u8[>..] = [];        // " pnpm bun": each once
        json::each(list) { p =>
            let k, k_ok = json::as_string(json::member(p, "kind"));
            let at, at_ok = json::as_string(json::member(p, "path"));
            if k_ok && k == kind && at_ok && !in_ignored(ignored, at) {
                n++;
                let m, m_ok = json::as_string(json::member(json::member(p, "package_manager"), "name"));
                if m_ok && m.len > 0 && find(str(managers, " "), str(" ", m, " ")) < 0 { format(managers, " ", m); }
            }
        };
        if n > 0 {
            if said.len > 0 { said.append(", "); }
            format(said, n, " ", kind);
            if managers.len > 0 { format(said, " (", managers[1..], ")"); }
            total += n;
        }
    }
    guard total > 0 else { return; }
    format(report, "projects: ", said, " (survey.json, read by Spread-Wings; nothing of the repo was run)\n");
    var node = 0;
    var bare = 0;
    json::each(list) { p =>
        let k, k_ok = json::as_string(json::member(p, "kind"));
        let at, at_ok = json::as_string(json::member(p, "path"));
        if k_ok && k == "node" && at_ok && !in_ignored(ignored, at) {
            node++;
            let inst, i_ok = json::as_bool(json::member(json::member(p, "dependencies_installed"), "installed"));
            if i_ok && !inst { bare++; }
        }
    };
    if bare > 0 {
        format(report, "node: dependencies are not installed in ", bare, " of ", node,
               " projects (no node_modules): what they import from packages is not in the map\n");
    }
}

// The survey's project folders that sit in folders git ignores, as a JSON
// list: the map leaves them out.
fn survey_left_out(survey: const u8[:], ignored: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.push('[');
    var text: u8[>..] = [];
    text.append(survey);
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(text, doc, dec);
    let list = json::member(root, "projects");
    if list {
        json::each(list) { p =>
            let at, at_ok = json::as_string(json::member(p, "path"));
            if at_ok && in_ignored(ignored, at) {
                if out.len > 1 { out.push(','); }
                json::format_string(out, at);
            }
        };
    }
    out.push(']');
    return out;
}
