// Running other programs: the SCIP indexers, the flattener and the
// compilers' checkers. Carried over from src/run.goose; the program is
// started by sys::run, which is native/swan_sys.c's swan_run.

use std::time::Instant;

use crate::sys;
use crate::util::{die, rfind};

// Swan's own folder: the parent of bin/, where tools/ and .tools/ live.
pub fn swan_home() -> Vec<u8> {
    let exe = match sys::exe_path() {
        Some(e) => e,
        None => die(b"swan: cannot find its own executable"),
    };
    let bin = rfind(&exe, b"/") as usize;
    let up = rfind(&exe[..bin], b"/") as usize;
    exe[..up].to_vec()
}

// Runs a step, prints a one-line account to stderr, and returns its exit
// code with stdout in `out`; stderr's tail goes in the account on failure.
pub fn run_step(label: &[u8], argv: &[&[u8]], cwd: &[u8], env: &[&[u8]], timeout_ms: i64, out: &mut Vec<u8>) -> i32 {
    let t0 = Instant::now();
    let mut err: Vec<u8> = Vec::new();
    let code = sys::run(argv, cwd, env, timeout_ms, out, &mut err);
    let ms = (t0.elapsed().as_secs_f64() * 1000.0) as i64;
    if code == 0 {
        sys::write_stderr(&[label, format!(": {} ms\n", ms).as_bytes()].concat());
    } else {
        let tail = if err.len() > 600 { &err[err.len() - 600..] } else { &err[..] };
        sys::write_stderr(&[label, format!(": exit {} after {} ms\n", code, ms).as_bytes(), tail, b"\n"].concat());
    }
    code
}
