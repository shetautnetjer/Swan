// The map: what `swan map` runs, in what order, and what it keeps.
//
// Carried over from src/pipeline.goose so far: `swan trust`. The walk at the
// head of that file is in walk.rs; the map itself is the rest of stage 4.

use crate::run::{run_step, swan_home};
use crate::sys;
use crate::util::contains_line;

// Some indexers and checkers run the repo's own build files: cargo's build
// scripts and proc macros, Maven and Gradle, MSBuild through `dotnet
// restore`. A repo can run any code that way, so they wait until a person
// says the repo is trusted: `swan trust <repo>` adds the repo's
// path to Swan's own data/trusted-repos, which no repo can ship (a record
// inside the map folder could, when that folder sits in the checkout).
// SWAN_TRUST_BUILD=1 trusts every repo, for tests and CI. Nothing in the
// MCP server writes it.
fn trust_file() -> Vec<u8> {
    [&swan_home()[..], b"/data/trusted-repos"].concat()
}

pub fn trust_main(repo_arg: &[u8], report: &mut Vec<u8>) -> bool {
    let repo = crate::abs_path(repo_arg);
    let tf = trust_file();
    let data = [&swan_home()[..], b"/data"].concat();
    let mut ignored: Vec<u8> = Vec::new();
    run_step(b"mkdir", &[b"mkdir", b"-p", &data], b"", &[], 10000, &mut ignored);
    let mut saved: Vec<u8> = Vec::new();
    sys::read_file(&tf, &mut saved);
    if !contains_line(&saved, &repo) {
        if !saved.is_empty() && saved[saved.len() - 1] != b'\n' {
            saved.push(b'\n');
        }
        saved.extend_from_slice(&repo);
        saved.push(b'\n');
        if !sys::write_file(&tf, &saved) {
            report.extend_from_slice(b"could not write ");
            report.extend_from_slice(&tf);
            return false;
        }
    }
    report.extend_from_slice(b"trusted ");
    report.extend_from_slice(&repo);
    report.extend_from_slice(b": swan map, swan check and live answers may now run its build files (Cargo, Maven, Gradle, MSBuild)");
    true
}
