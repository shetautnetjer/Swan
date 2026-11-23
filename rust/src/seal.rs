// Running children sealed (eggshell): every repo is sealed; trust only adds
// the network and a few writable folders.
//
// Carried over from src/seal.goose. The toolchains a sealed child is told
// about (the rest of that file) are in rustproj.rs, where stage 2 first
// needed them.

use crate::run::{run_step, swan_home};
use crate::rustproj::toolchain_home;
use crate::sys;

// Sealed by default. SWAN_SANDBOX=0 turns the seal off (indexers run the old
// way); anything else, including unset, means on.
pub fn sandbox_on() -> bool {
    sys::env(b"SWAN_SANDBOX") != b"0"
}

// Whether this process already runs inside eggshell's seal (it exports
// EGG_REPO): what it starts is sealed with it, and sealing that again would
// need namespaces the seal does not hand out (src/live.goose, inside_seal).
pub fn inside_seal() -> bool {
    !sys::env(b"EGG_REPO").is_empty()
}

// Wrap a child's argv so it runs sealed via <swan_home>/bin/eggshell:
//   eggshell <repo> <out> [--allow-net --rw <dir>...] -- <inner argv...>
// Every repo is sealed: no host writes except the map dir, no host sockets.
// Trust only loosens the seal: a trusted repo gets the network and the
// writable directories its build tools need (the repo itself for obj/ and
// build/, Cargo's home, Swan's Gradle, .NET and Go module caches); it never runs
// unsealed. The runner refuses (exit 3) if the kernel cannot seal, which
// surfaces as a failed step rather than an unconfined run.
pub fn seal_argv(inner: &[&[u8]], repo: &[u8], out: &[u8], trusted: bool) -> Vec<Vec<u8>> {
    let home = swan_home();
    let mut a: Vec<Vec<u8>> = vec![[&home[..], b"/bin/eggshell"].concat(), repo.to_vec(), out.to_vec()];
    if trusted {
        a.push(b"--allow-net".to_vec());
        let t = [&home[..], b"/.tools"].concat();
        let rw: [Vec<u8>; 6] = [
            repo.to_vec(),
            toolchain_home(b"CARGO_HOME", b".cargo"),
            [&t[..], b"/gradle-home"].concat(),
            [&t[..], b"/dotnet-home"].concat(),
            [&t[..], b"/nuget"].concat(),
            [&t[..], b"/go-mod"].concat(), // Go's module cache: a trusted repo's dependencies are fetched into it
        ];
        for dir in rw {
            a.push(b"--rw".to_vec());
            a.push(dir);
        }
    }
    a.push(b"--".to_vec());
    a.extend(inner.iter().map(|s| s.to_vec()));
    a
}

// Run one step of the map sealed when the sandbox is on (see seal_argv).
#[allow(clippy::too_many_arguments)]
pub fn sealed_run(argv: &[&[u8]], repo: &[u8], out: &[u8], trusted: bool, env: &[&[u8]], timeout_ms: i64, o: &mut Vec<u8>, e: &mut Vec<u8>) -> i32 {
    if !sandbox_on() {
        return sys::run(argv, repo, env, timeout_ms, o, e);
    }
    let sealed = seal_argv(argv, repo, out, trusted);
    let sealed: Vec<&[u8]> = sealed.iter().map(|s| &s[..]).collect();
    sys::run(&sealed, repo, env, timeout_ms, o, e)
}

#[allow(dead_code, clippy::too_many_arguments)]
pub fn sealed_step(label: &[u8], argv: &[&[u8]], repo: &[u8], out: &[u8], trusted: bool, env: &[&[u8]], timeout_ms: i64, o: &mut Vec<u8>) -> i32 {
    if !sandbox_on() {
        return run_step(label, argv, repo, env, timeout_ms, o);
    }
    let sealed = seal_argv(argv, repo, out, trusted);
    let sealed: Vec<&[u8]> = sealed.iter().map(|s| &s[..]).collect();
    run_step(label, &sealed, repo, env, timeout_ms, o)
}
