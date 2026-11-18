// Running children sealed (eggshell), and the toolchains a sealed child is
// told about: every repo is sealed; trust only adds the network and a few
// writable folders.

import std;
import os;
import json;
import dictionary;
import sqlite;

// Sealed by default. SWAN_SANDBOX=0 turns the seal off (indexers run the old
// way); anything else, including unset, means on.
fn sandbox_on() -> bool {
    var v: u8[>..] = [];
    if env("SWAN_SANDBOX", v) && v == "0" { return false; }
    return true;
}

// Wrap a child's argv so it runs sealed via <swan_home>/bin/eggshell:
//   eggshell <repo> <out> [--allow-net --rw <dir>...] -- <inner argv...>
// Every repo is sealed: no host writes except the map dir, no host sockets.
// Trust only loosens the seal: a trusted repo gets the network and the
// writable directories its build tools need (the repo itself for obj/ and
// build/, Cargo's home, Swan's Gradle and .NET caches); it never runs
// unsealed. The runner refuses (exit 3) if the kernel cannot seal, which
// surfaces as a failed step rather than an unconfined run.
fn seal_argv(inner: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool) -> u8[>..] {
    var a: u8[>..] = [];
    arg(a, str(swan_home(), "/bin/eggshell"));
    arg(a, repo);
    arg(a, out);
    if trusted {
        arg(a, "--allow-net");
        let t = str(swan_home(), "/.tools");
        arg(a, "--rw"); arg(a, repo);
        arg(a, "--rw"); arg(a, toolchain_home("CARGO_HOME", ".cargo"));
        arg(a, "--rw"); arg(a, str(t, "/gradle-home"));
        arg(a, "--rw"); arg(a, str(t, "/dotnet-home"));
        arg(a, "--rw"); arg(a, str(t, "/nuget"));
    }
    arg(a, "--");
    a.append(inner);
    return a;
}

// $VAR if set, else $HOME/<sub>: where rustup and Cargo keep toolchains and
// crates. Sealed children get a scratch HOME, so these are passed explicitly.
fn toolchain_home(name: const u8[:], sub: const u8[:]) -> u8[>..] {
    var v: u8[>..] = [];
    if env(name, v) && v.len > 0 { return v; }
    var h: u8[>..] = [];
    env("HOME", h);
    return str(h, "/", sub);
}

// Passes $VAR to a sealed child when this machine keeps that folder where
// toolchain_home says: $VAR is set, or $HOME/<sub> is there. Otherwise the
// variable is left alone. A machine with rustup installed for everyone has
// no ~/.rustup: its `cargo` is a small script that sets RUSTUP_HOME itself
// when nothing else did, and naming ~/.rustup made rustup try to create it
// inside the seal ("could not create home directory ... Read-only file
// system"), so every Rust map there failed (found 2026-11-17 in a clean
// Ubuntu microVM).
fn add_toolchain_env(renv: u8[>..]&, name: const u8[:], sub: const u8[:]) {
    var v: u8[>..] = [];
    let p = toolchain_home(name, sub);
    if (env(name, v) && v.len > 0) || is_dir(p) { renv.append(env_entry(name, p)); }
}

// The toolchain to index with when the repo pins one rustup does not have
// (rust-toolchain.toml or rust-toolchain: `channel = "1.88.0"`): rustup's
// default one, else "". Without this cargo exits "toolchain ... is not
// installed" and the repo gets no Rust map at all; a sealed, offline run
// cannot install it, and a map does not need the exact compiler. Found on
// relatedb/relate, 2026-11-17.
fn rust_toolchain_override(repo: const u8[:]) -> u8[>..] {
    var none: u8[>..] = [];
    var text: u8[>..] = [];
    var channel: u8[>..] = [];
    if read_file(str(repo, "/rust-toolchain.toml"), text) {
        each_split(text, '\n') { l =>
            let t = trim(l);
            if channel.len == 0 && starts_with(t, "channel") && find(t, "\"") >= 0 {
                let a = find(t, "\"") + 1;
                let b = a + find(t[a..], "\"");
                if b > a { channel.append(t[a..b]); }
            }
        };
    } else if read_file(str(repo, "/rust-toolchain"), text) {
        each_split(text, '\n') { l => if channel.len == 0 && trim(l).len > 0 && find(l, "[") < 0 && find(l, "=") < 0 { channel.append(trim(l)); } };
    }
    guard channel.len > 0 else { return none; }
    // Where rustup keeps toolchains: $RUSTUP_HOME or ~/.rustup, else what
    // rustup itself says (installed for everyone, its home is elsewhere and
    // only its wrapper scripts know). Asked from /, never from the repo:
    // there rustup would try to install the pinned toolchain.
    var rh: u8[>..] = [];
    rh.append(toolchain_home("RUSTUP_HOME", ".rustup"));
    if !is_dir(str(rh, "/toolchains")) {
        var a: u8[>..] = [];
        arg(a, "rustup"); arg(a, "show"); arg(a, "home");
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        guard swan_run(a, "/", "", 10000, o, e) == 0 else { return none; }
        rh.clear();
        rh.append(trim(o));
    }
    var names: u8[>..] = [];
    guard list_dir(str(rh, "/toolchains"), names) else { return none; }
    var have = false;
    each_split(names, '\n') { n => if n == channel || starts_with(n, str(channel, "-")) { have = true; } };
    guard !have else { return none; }
    var settings: u8[>..] = [];
    var dflt: u8[>..] = [];
    if read_file(str(rh, "/settings.toml"), settings) {
        each_split(settings, '\n') { l =>
            let t = trim(l);
            if dflt.len == 0 && starts_with(t, "default_toolchain") && find(t, "\"") >= 0 {
                let a = find(t, "\"") + 1;
                let b = a + find(t[a..], "\"");
                if b > a { dflt.append(t[a..b]); }
            }
        };
    }
    guard dflt.len > 0 else { return none; }
    write_stderr(str("rust: the repo pins toolchain ", channel, ", which is not installed; indexing with ", dflt, "\n"));
    return dflt;
}

// Run one step of the map sealed when the sandbox is on (see seal_argv).
fn sealed_run(argv: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool, env: const u8[:],
              timeout_ms: i64, o: u8[>..]&, e: u8[>..]&) -> i32 {
    if !sandbox_on() { return swan_run(argv, repo, env, timeout_ms, o, e); }
    return swan_run(seal_argv(argv, repo, out, trusted)[..], repo, env, timeout_ms, o, e);
}

fn sealed_step(label: const u8[:], argv: const u8[:], repo: const u8[:], out: const u8[:], trusted: bool,
               env: const u8[:], timeout_ms: i64, o: u8[>..]&) -> i32 {
    if !sandbox_on() { return run_step(label, argv, repo, env, timeout_ms, o); }
    return run_step(label, seal_argv(argv, repo, out, trusted)[..], repo, env, timeout_ms, o);
}
