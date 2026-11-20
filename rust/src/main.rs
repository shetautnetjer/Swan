// Swan: a code map for agents. SCIP data in, SQLite map, MCP tools out.
//   swan index <flattened-dir> <db> [repo-root]     a new map
//   swan refresh <flattened-dir> <db> [repo-root]   rewrite only the files whose rows changed
//   swan query <db> symbol|refs|uses|at|overview|callers|callees|impls|hierarchy|unused|info|diag|diagfile|pattern <arg> [relative_path]
//   swan serve [<db> | --maps <data-root>]   MCP over stdio
//
// Carried over from src/swan.goose (docs/rust-port.md has the bar and the
// stages). A command whose stage is not carried over yet says so and exits
// with NOT_CARRIED, so a comparison can tell "not yet" from "wrong".

use std::io::Write;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::process::exit;

const USAGE: &str = "\
usage: swan map <repo> <out-dir> [--clean]  index or refresh; --clean bypasses all cached output
       swan doctor [--profile core|python-typescript] [--json]
       swan check <repo> <out-dir>      run compilers and linters into the map
       swan broke <out-dir> <file>...   errors new in these files since last asked (exit 1 if any)
       swan trust <repo>                let map, check and live answers run the repo's build files
       swan gradle-tasks <repo>         the Gradle tasks map would give scip-java (runs nothing)
       swan cargo-projects <repo>       the cargo projects map would run rust-analyzer in, with its settings (runs nothing)
       swan lsp-index <repo> <out-dir> <lang> <target.scip> [--within <folder>]   a SCIP index from the language's server (what swan map runs); --within: only that folder of the repo, the server started in it
       swan lsp-ask <repo> <out-dir> <file> <method> [line col] [more]   one question to the file's language server
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

fn not_carried(command: &[u8], stage: u8) -> ! {
    let mut msg = b"swan (rust): ".to_vec();
    msg.extend_from_slice(command);
    msg.extend_from_slice(format!(" is not carried over yet (stage {stage} of docs/rust-port.md)\n").as_bytes());
    let _ = std::io::stderr().write_all(&msg);
    exit(NOT_CARRIED);
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
        for arg in &a[2..] {
            // Diagnose this executable's installation, never a caller-supplied
            // repository passed off as a different runtime home.
            if arg.as_slice() == b"--home" || arg.starts_with(b"--home=") {
                usage();
            }
        }
        not_carried(cmd, 4);
    } else if cmd == b"index" && n >= 4 {
        not_carried(cmd, 1);
    } else if cmd == b"refresh" && n >= 4 {
        not_carried(cmd, 1);
    } else if cmd == b"query" && n >= 5 {
        const KINDS: [&str; 14] = [
            "symbol", "refs", "uses", "overview", "callers", "callees", "unused", "info", "at",
            "diag", "diagfile", "impls", "hierarchy", "pattern",
        ];
        // The Goose program opens the map before it looks at the kind, so a
        // missing map is reported before an unknown kind.
        if !std::path::Path::new(std::ffi::OsStr::from_bytes(&a[2])).is_file() {
            let mut msg = b"swan: no index at ".to_vec();
            msg.extend_from_slice(&a[2]);
            msg.push(b'\n');
            let _ = std::io::stderr().write_all(&msg);
            exit(1);
        }
        if !KINDS.iter().any(|k| is(3, k)) {
            usage();
        }
        not_carried(cmd, 1);
    } else if cmd == b"map" && (n == 4 || (n == 5 && is(4, "--clean"))) {
        not_carried(cmd, 4);
    } else if cmd == b"syntax-index" && (n == 4 || (n == 6 && is(4, "--skip"))) {
        not_carried(cmd, 3);
    } else if cmd == b"plan-python" && (n == 3 || n == 4) {
        if n == 4 {
            let ok = std::str::from_utf8(&a[3]).ok().and_then(|s| s.parse::<i64>().ok()).is_some_and(|v| v > 0);
            if !ok {
                usage();
            }
        }
        not_carried(cmd, 2);
    } else if cmd == b"scip-python-patch" && (n == 3 || (n == 4 && is(3, "--revert"))) {
        not_carried(cmd, 4);
    } else if cmd == b"scip-typescript-patch" && (n == 3 || (n == 4 && is(3, "--revert"))) {
        not_carried(cmd, 4);
    } else if cmd == b"stamp-bench" && n == 4 {
        not_carried(cmd, 2);
    } else if cmd == b"stamp-worker" && n == 6 {
        not_carried(cmd, 2);
    } else if cmd == b"trust" && n == 3 {
        not_carried(cmd, 4);
    } else if cmd == b"gradle-tasks" && n == 3 {
        not_carried(cmd, 2);
    } else if cmd == b"cargo-projects" && n == 3 {
        not_carried(cmd, 2);
    } else if cmd == b"check" && n == 4 {
        not_carried(cmd, 6);
    } else if cmd == b"broke" && n >= 4 {
        not_carried(cmd, 6);
    } else if cmd == b"lsp-index" && (n == 6 || (n == 8 && is(6, "--within"))) {
        not_carried(cmd, 5);
    } else if cmd == b"lsp-ask" && n >= 6 {
        not_carried(cmd, 5);
    } else if cmd == b"format" && n >= 5 {
        not_carried(cmd, 6);
    } else if cmd == b"test" && n >= 5 {
        not_carried(cmd, 6);
    } else if cmd == b"diagnostics" && n == 4 {
        not_carried(cmd, 6);
    } else if cmd == b"serve" && n == 3 {
        not_carried(cmd, 7);
    } else if cmd == b"serve" && (n == 2 || (n == 4 && is(2, "--maps"))) {
        not_carried(cmd, 7);
    } else {
        usage();
    }
}
