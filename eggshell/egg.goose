// egg.goose — pure-Goose typed front end for the egg-shell sandbox.
//
// It validates a sandbox request (Pydantic-style: check on construction) and
// builds the sealed command line that the `eggshell` runner then executes with
// no network and the repo read-only. The kernel-level sealing stays in the
// runner: Goose v1 has no subprocess library (see Swan's src/run.goose), so a
// pure-Goose program cannot spawn — it hands a sealed argv to the runner.
//
// Borrowed ideas, as ideas not code:
//   - Pydantic: validate on construction, typed fields.  (pydantic docs)
//   - Monty: Goose's take on that same model.            (shetautnetjer/the-full-monty)
//   - "code mode": agents call ONE typed entry point (run_sealed) and get a
//     checked result, instead of many ad-hoc tool calls.  (code-mode pattern)
//
// Build:  goose build egg.goose        (needs a C compiler; no cmake, no packages)
// Run:    egg <repo> <out> [--allow-net] -- <cmd...>

import std;
import os;

struct SandboxConfig {
    repo: const u8[:],
    out: const u8[:],
    allow_net: bool,
    cmd: const u8[:],     // NUL-separated argv of the indexer to seal
}

// argv entries travel NUL-separated, matching Swan's src/run.goose convention.
fn arg(list: u8[>..]&, a: const u8[:]) {
    list.append(a);
    list.push(0);
}

// Pydantic-style validate-on-construct. Writes the first problem into `err`
// (empty err means valid). Mirrors the shell runner's own preconditions.
fn make_config(repo: const u8[:], out: const u8[:], allow_net: bool, cmd: const u8[:],
               err: u8[>..]&) -> SandboxConfig {
    if repo.len == 0 { err.append("repo must not be empty"); }
    else if out.len == 0 { err.append("out must not be empty"); }
    else if out == "/tmp" || starts_with(out, "/tmp/") {
        err.append("out must not be under /tmp (ephemeral scratch lives there)");
    }
    else if cmd.len == 0 { err.append("cmd must not be empty"); }
    return SandboxConfig { repo: repo, out: out, allow_net: allow_net, cmd: cmd };
}

// code-mode single entry point: produce the sealed argv for the runner,
//   eggshell <repo> <out> [--allow-net] -- <cmd...>
fn run_sealed(cfg: SandboxConfig, out_argv: u8[>..]&) {
    arg(out_argv, "eggshell");
    arg(out_argv, cfg.repo);
    arg(out_argv, cfg.out);
    if cfg.allow_net { arg(out_argv, "--allow-net"); }
    arg(out_argv, "--");
    out_argv.append(cfg.cmd);     // already NUL-separated
}

// Render a NUL-separated argv with spaces, for printing.
fn show(buf: const u8[:]) -> u8[>..] {
    var s: u8[>..] = [];
    for b in buf { if b == 0 { s.push(' '); } else { s.push(b); } }
    return s;
}

fn main() {
    let a = args();
    if a.len < 5 {
        write_stderr("usage: egg <repo> <out> [--allow-net] -- <cmd...>\n");
        exit(2);
    }
    let repo = a[1];
    let out = a[2];
    var i = 3;
    var allow_net = false;
    if a[i] == "--allow-net" { allow_net = true; i += 1; }
    if a[i] != "--" {
        write_stderr("egg: expected -- before the command\n");
        exit(2);
    }
    i += 1;
    var cmd: u8[>..] = [];
    for k in i..a.len { arg(cmd, a[k]); }

    var err: u8[>..] = [];
    let cfg = make_config(repo, out, allow_net, cmd[..], err);
    if err.len > 0 {
        write_stderr(str("egg: invalid config: ", err, "\n"));
        exit(2);
    }
    var sealed: u8[>..] = [];
    run_sealed(cfg, sealed);
    print(str(show(sealed[..]), "\n"));
}
