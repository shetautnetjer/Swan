// Swan: a code map for agents. SCIP data in, SQLite map, MCP tools out.
//   swan index <flattened-dir> <db> [repo-root]     a new map
//   swan refresh <flattened-dir> <db> [repo-root]   rewrite only the files whose rows changed
//   swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
//   swan serve [<db> | --maps <data-root>]   MCP over stdio
//
// Carried over from src/swan.goose (docs/rust-port.md has the bar and the
// stages). A command whose stage is not carried over yet says so and exits
// with NOT_CARRIED, so a comparison can tell "not yet" from "wrong".

mod broke;
mod change;
mod db;
mod diag;
mod edit;
mod fresh;
mod gsort;
mod gradle;
mod graph;
mod index;
mod json;
mod live;
mod lsp;
mod lspindex;
mod modules;
mod pipeline;
mod pypatch;
mod pyplan;
mod query;
mod run;
mod rustproj;
mod scip;
mod seal;
mod serve;
mod serve_forward;
mod serve_read;
mod serve_repo;
mod serve_tools;
mod serve_wings;
mod stamp;
mod structural;
mod survey;
mod syntax;
mod sys;
mod treesitter;
mod tsproj;
mod tspatch;
mod util;
mod walk;
mod wings;

use std::io::Write;
use std::os::unix::ffi::OsStringExt;
use std::process::exit;
use util::{die, parse_int, print, split};

const USAGE: &str = "\
usage: swan map <repo> <out-dir> [--clean]  index or refresh; --clean bypasses all cached output
       swan doctor [--profile core|python-typescript] [--json]
       swan check <repo> <out-dir>      run compilers and linters into the map
       swan broke <out-dir> <file>...   errors new in these files since last asked (exit 1 if any; 3 if none but a file could not be asked)
       swan trust <repo>                let map, check and live answers run the repo's build files
       swan gradle-tasks <repo>         the Gradle tasks map would give scip-java (runs nothing)
       swan cargo-projects <repo>       the cargo projects map would run rust-analyzer in, with its settings (runs nothing)
       swan lsp-index <repo> <out-dir> <lang> <target.scip> [--within <folder>]   a SCIP index from the language's server (what swan map runs); --within: only that folder of the repo, the server started in it
       swan lsp-ask <repo> <out-dir> <file> <method> [line col] [more]   one question to the file's language server; line and col from 1, in the server's units (UTF-16 code units unless it says otherwise); more: members for the params, as JSON
       swan format <repo> <out-dir> <file>...
       swan test <repo> <out-dir> <name_path|file> [relative_path]
       swan index <flattened-dir> <db> [repo-root]
       swan refresh <flattened-dir> <db> [repo-root]
       swan diagnostics <dir-with-diagnostics.tsv> <db>
       swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
       swan serve [<db> | --maps <data-root>]
";

/// Exit code of a command whose stage is not carried over yet. Not a code
/// the Goose program gives (it uses 0, 1 and 2).
const NOT_CARRIED: i32 = 70;

fn usage() -> ! {
    let _ = std::io::stderr().write_all(USAGE.as_bytes());
    exit(2);
}

pub(crate) fn not_carried(command: &[u8], stage: u8) -> ! {
    let mut msg = b"swan (rust): ".to_vec();
    msg.extend_from_slice(command);
    msg.extend_from_slice(format!(" is not carried over yet (stage {stage} of docs/rust-port.md)\n").as_bytes());
    let _ = std::io::stderr().write_all(&msg);
    exit(NOT_CARRIED);
}

// The map at path, for a job of its own: the freshness state stays with the
// connection that answers questions.
fn open_map(path: &[u8]) -> db::Db {
    if !sys::file_exists(path) {
        die(&[b"swan: no index at ", path].concat());
    }
    match db::Db::open_existing(path) {
        Ok(db) => db,
        Err(e) => die(&[b"swan: cannot open ", path, b": ", &e[..]].concat()),
    }
}

fn open_db(path: &[u8]) -> (db::Db, fresh::Fresh) {
    let db = open_map(path);
    // CLI queries, like read-only MCP tools, use one database generation
    // across freshness metadata and all statements that build their answer.
    db.exec_or_die(b"BEGIN;");
    let version = query::meta_value(&db, b"schema_version");
    let reads = index::SCHEMA_VERSION.to_string().into_bytes();
    if version != reads {
        die(&[b"swan: index schema ", &version[..], b", this swan reads ", &reads[..], b"; rebuild the map"].concat());
    }
    let fr = fresh::Fresh::load(&db);
    (db, fr)
}

fn main() {
    // Arguments are bytes: a path need not be UTF-8.
    let a: Vec<Vec<u8>> = std::env::args_os().map(|s| s.into_vec()).collect();
    if a.len() < 2 {
        usage();
    }
    let cmd = a[1].as_slice();
    let n = a.len();
    let is = |k: usize, s: &str| a[k].as_slice() == s.as_bytes();

    // The same shapes, in the same order, as main() in src/swan.goose.
    if cmd == b"doctor" {
        let home = run::swan_home();
        let script = [&home[..], b"/scripts/doctor.py"].concat();
        let mut argv: Vec<&[u8]> = vec![b"python3", b"-I", &script, b"--home", &home];
        for arg in &a[2..] {
            // Diagnose this executable's installation, never a caller-supplied
            // repository passed off as a different runtime home.
            if arg.as_slice() == b"--home" || arg.starts_with(b"--home=") {
                usage();
            }
            argv.push(arg);
        }
        let mut result: Vec<u8> = Vec::new();
        let code = run::run_step(b"doctor", &argv, &home, &[b"PATH=/usr/local/bin:/usr/bin:/bin"], 60000, &mut result);
        print(&result);
        exit(code);
    } else if cmd == b"index" && n >= 4 {
        let mut report: Vec<u8> = Vec::new();
        index::index_main(&a[2], &a[3], if n > 4 { &a[4] } else { b"" }, false, &mut report);
        print(&report);
    } else if cmd == b"refresh" && n >= 4 {
        let mut report: Vec<u8> = Vec::new();
        index::index_main(&a[2], &a[3], if n > 4 { &a[4] } else { b"" }, true, &mut report);
        print(&report);
    } else if cmd == b"query" && n >= 5 {
        // The map is opened before the kind is looked at, so a missing map is
        // reported before an unknown kind.
        let (db, fr) = open_db(&a[2]);
        let rel: &[u8] = if n > 5 { &a[5] } else { b"" };
        let kind = a[3].as_slice();
        let arg = a[4].as_slice();
        let mut out: Vec<u8> = Vec::new();
        if kind == b"symbol" {
            query::find_symbol(&db, &fr, arg, rel, false, true, 50, &mut out);
        } else if kind == b"refs" {
            query::find_referencing_symbols(&db, &fr, arg, rel, 500, false, &mut out);
        } else if kind == b"uses" {
            query::find_referencing_symbols(&db, &fr, arg, rel, 2000, true, &mut out);
        } else if kind == b"overview" {
            query::get_symbols_overview(&db, &fr, arg, &mut out);
        } else if kind == b"callers" {
            graph::get_callers(&db, &fr, arg, rel, 3, 200, &mut out);
        } else if kind == b"callees" {
            graph::get_callees(&db, &fr, arg, rel, false, 200, &mut out);
        } else if kind == b"unused" {
            graph::find_unused_symbols(&db, &fr, arg, false, 200, &mut out);
        } else if kind == b"info" {
            query::index_info(&db, &fr, &mut out);
        } else if kind == b"at" {
            let p = split(arg, b':');
            if p.len() != 3 {
                die(b"swan query <db> at <file>:<line>:<column>");
            }
            // A part that is not a number counts as 0, as in the Goose program.
            let ln = parse_int(p[1]).unwrap_or(0);
            let cn = parse_int(p[2]).unwrap_or(0);
            query::get_symbol_at(&db, &fr, p[0], ln, cn, &mut out);
        } else if kind == b"diag" {
            diag::get_diagnostics(&db, &fr, arg, rel, 2, false, 200, &mut out);
        } else if kind == b"diagfile" {
            diag::get_diagnostics(&db, &fr, b"", arg, 0, false, 200, &mut out);
        } else if kind == b"impls" {
            graph::find_implementations(&db, &fr, arg, rel, 200, &mut out);
        } else if kind == b"hierarchy" {
            graph::get_type_hierarchy(&db, &fr, arg, rel, 3, 200, &mut out);
        } else if kind == b"pattern" {
            structural::search_pattern(&db, &fr, arg, b"", rel, 1000000, &mut out);
        } else {
            usage();
        }
        db.exec_or_die(b"COMMIT;");
        // The freshness statement belongs to this connection, so it goes first.
        drop(fr);
        drop(db);
        print(&out);
    } else if cmd == b"map" && (n == 4 || (n == 5 && is(4, "--clean"))) {
        let mut report: Vec<u8> = Vec::new();
        let ok = pipeline::map_main(&a[2], &a[3], &mut report, n == 5);
        print(&report);
        if !ok {
            exit(1);
        }
    } else if cmd == b"syntax-index" && (n == 4 || (n == 6 && (is(4, "--skip") || is(4, "--skip-files")))) {
        let skip_go = n == 6 && is(4, "--skip") && is(5, "go");
        let mut skip = std::collections::HashSet::new();
        if n == 6 && is(4, "--skip-files") {
            let mut list = Vec::new();
            if !sys::read_file(&a[5], &mut list) {
                die(&[b"swan syntax-index: cannot read ", &a[5][..]].concat());
            }
            skip.extend(list.split(|&c| c == b'\n').filter(|p| !p.is_empty()).map(<[u8]>::to_vec));
        }
        if !syntax::syntax_index_main(&a[2], &a[3], skip_go, &skip) {
            exit(1);
        }
    } else if cmd == b"plan-python" && (n == 3 || n == 4) {
        // The Python pieces a map would index in parallel, one per line ("" = the whole repo).
        let mut k: i64 = 6;
        if n == 4 {
            match parse_int(&a[3]) {
                Some(v) if v > 0 => k = v,
                _ => usage(),
            }
        }
        write_stdout(&pyplan::plan_python(&walk::Walk::default(), &abs_path(&a[2]), k));
    } else if cmd == b"scip-python-patch" && (n == 3 || (n == 4 && is(3, "--revert"))) {
        // Applies (or undoes) Swan's fixes on one file of scip-python: the
        // reachability memo on pyright-internal.js, the package names and
        // Python version on scip-python.js.
        let r = if util::ends_with(&a[2], b"scip-python.js") { pypatch::pysite_file(&a[2], n == 4) } else { pypatch::pypatch_file(&a[2], n == 4) };
        print(r);
        if r == b"no match" {
            exit(1);
        }
    } else if cmd == b"scip-typescript-patch" && (n == 3 || (n == 4 && is(3, "--revert"))) {
        // Applies (or undoes) the stable names on one scip-typescript FileIndexer.js.
        let r = tspatch::tspatch_file(&a[2], n == 4);
        print(r);
        if r == b"no match" {
            exit(1);
        }
    } else if cmd == b"stamp-bench" && n == 4 {
        if !stamp::stamp_bench_main(&a[2], &a[3]) {
            exit(1);
        }
    } else if cmd == b"stamp-worker" && n == 6 {
        if !stamp::stamp_worker_main(&a[2], &a[3], &a[4], &a[5]) {
            exit(1);
        }
    } else if cmd == b"trust" && n == 3 {
        let mut report: Vec<u8> = Vec::new();
        let ok = pipeline::trust_main(&a[2], &mut report);
        print(&report);
        if !ok {
            exit(1);
        }
    } else if cmd == b"gradle-tasks" && n == 3 {
        write_stdout(&gradle::gradle_scip_tasks(&walk::Walk::default(), &abs_path(&a[2])));
    } else if cmd == b"cargo-projects" && n == 3 {
        write_stdout(&rustproj::cargo_projects_report(&abs_path(&a[2])));
    } else if cmd == b"check" && n == 4 {
        not_carried(cmd, 6);
    } else if cmd == b"broke" && n >= 4 {
        exit(broke::broke_main(&a[2], &a[3..]));
    } else if cmd == b"lsp-index" && (n == 6 || (n == 8 && is(6, "--within"))) {
        if !lspindex::lsp_index_main(&abs_path(&a[2]), &abs_path(&a[3]), &a[4], &a[5], if n == 8 { &a[7] } else { b"" }) {
            exit(1);
        }
    } else if cmd == b"lsp-ask" && (6..=9).contains(&n) {
        let Ok(method) = std::str::from_utf8(&a[5]) else { usage() };
        let from_1 = |s: &[u8]| parse_int(s).filter(|&v| v >= 1 && v <= u32::MAX as i64).map(|v| v as u32);
        let place = match n {
            8 | 9 => match (from_1(&a[6]), from_1(&a[7])) {
                (Some(line), Some(col)) => Some((line, col)),
                _ => usage(),
            },
            _ => None,
        };
        let more: &[u8] = match n {
            7 => &a[6],
            9 => &a[8],
            _ => b"",
        };
        if !live::lsp_ask_main(&a[2], &a[3], &a[4], method, place, more) {
            exit(1);
        }
    } else if cmd == b"format" && n >= 5 {
        not_carried(cmd, 6);
    } else if cmd == b"test" && n >= 5 {
        not_carried(cmd, 6);
    } else if cmd == b"diagnostics" && n == 4 {
        not_carried(cmd, 6);
    } else if cmd == b"serve" && n == 3 {
        exit(serve::serve_main(&a[2]));
    } else if cmd == b"serve" && (n == 2 || (n == 4 && is(2, "--maps"))) {
        let maps_root = if n == 4 {
            a[3].clone()
        } else {
            [&run::swan_home()[..], b"/data"].concat()
        };
        exit(serve::serve_any(&maps_root));
    } else {
        usage();
    }
}

/// The real path of a path given on the command line; it ends the run when
/// there is none (src/pipeline.goose, abs_path).
pub(crate) fn abs_path(p: &[u8]) -> Vec<u8> {
    match sys::realpath(p) {
        Some(o) => o,
        None => die(&[&b"swan: no such path: "[..], p].concat()),
    }
}

/// Goose's write_stdout: the bytes as they are, no line end added.
fn write_stdout(text: &[u8]) {
    let out = std::io::stdout();
    let mut out = out.lock();
    let _ = out.write_all(text);
    let _ = out.flush();
}
