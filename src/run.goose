// Running other programs: the SCIP indexers, the flattener and the
// compilers' checkers. Goose v1 has no subprocess library; its docs say
// subprocesses "arrive as extern fns when a program needs them", and this
// is that, through native/swan_sqlite.c.

import std;
import os;

extern fn swan_run(argv: const u8[:], cwd: const u8[:], env: const u8[:], timeout_ms: i64,
                   out: u8[>..]&, err: u8[>..]&) -> i32;
extern fn swan_exe_path(out: u8[>..]&) -> bool;

// Arguments and environment entries travel NUL-separated.
fn arg(list: u8[>..]&, a: const u8[:]) {
    list.append(a);
    list.push(0);
}

// Swan's own folder: the parent of bin/, where tools/ and .tools/ live.
fn swan_home() -> u8[>..] {
    var exe: u8[>..] = [];
    guard swan_exe_path(exe) else { abort("swan: cannot find its own executable"); }
    var home: u8[>..] = [];
    let bin = rfind(exe, "/");
    let up = rfind(exe[..bin], "/");
    home.append(exe[..up]);
    return home;
}

// Runs a step, prints a one-line account to stderr, and returns its exit
// code with stdout in `out`; stderr's tail goes in the account on failure.
fn run_step(label: const u8[:], argv: const u8[:], cwd: const u8[:], env: const u8[:],
            timeout_ms: i64, out: u8[>..]&) -> i32 {
    let t0 = clock();
    var err: u8[>..] = [];
    let code = swan_run(argv, cwd, env, timeout_ms, out, err);
    let ms = ((clock() - t0) * 1000.0) as i64;
    if code == 0 {
        write_stderr(str(label, ": ", ms, " ms\n"));
    } else {
        let tail = if err.len > 600 { err[err.len - 600..] } else { err[..] };
        write_stderr(str(label, ": exit ", code, " after ", ms, " ms\n", tail, "\n"));
    }
    return code;
}
