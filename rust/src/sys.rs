// What the program asks the system: files, times, folders, and the lock one
// writer holds on a map. Carried over from native/swan_sys.c and the parts
// of Goose's os module Swan uses.

use std::ffi::{CStr, CString, OsStr};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::ffi::OsStringExt;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

pub fn path(p: &[u8]) -> &Path {
    Path::new(OsStr::from_bytes(p))
}

/// True when the path itself is a symbolic link (not followed).
pub fn is_symlink(p: &[u8]) -> bool {
    fs::symlink_metadata(path(p)).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

pub fn is_dir(p: &[u8]) -> bool {
    fs::metadata(path(p)).map(|m| m.is_dir()).unwrap_or(false)
}

/// A file, not a directory.
pub fn file_exists(p: &[u8]) -> bool {
    fs::metadata(path(p)).map(|m| m.is_file()).unwrap_or(false)
}

/// A file's modification time in nanoseconds since the epoch, or -1 if it
/// cannot be read.
pub fn mtime_ns(p: &[u8]) -> i64 {
    if p.is_empty() || p.len() >= 4096 {
        return -1;
    }
    fs::metadata(path(p)).map(|m| m.mtime() * 1_000_000_000 + m.mtime_nsec()).unwrap_or(-1)
}

/// Wall clock, nanoseconds since the epoch.
pub fn time_ns() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as i64).unwrap_or(0)
}

/// The names in a folder, without `.` and `..`, sorted bytewise. None when
/// it cannot be read.
pub fn list_dir(dir: &[u8]) -> Option<Vec<Vec<u8>>> {
    let rd = fs::read_dir(path(dir)).ok()?;
    let mut names: Vec<Vec<u8>> = Vec::new();
    for e in rd {
        match e {
            Ok(e) => names.push(e.file_name().as_bytes().to_vec()),
            Err(_) => return None,
        }
    }
    names.sort();
    Some(names)
}

/// Appends the whole file to out; false (and out as it was) when it cannot
/// be read. Read straight into out: a rows file can be a hundred megabytes,
/// and a second copy of it, even for a moment, is the peak of a refresh.
pub fn read_file(p: &[u8], out: &mut Vec<u8>) -> bool {
    use std::io::Read;
    let was = out.len();
    let ok = match fs::File::open(path(p)) {
        Ok(mut f) => f.read_to_end(out).is_ok(),
        Err(_) => false,
    };
    if !ok {
        out.truncate(was);
    }
    ok
}

/// Writes the whole file, replacing what was there; false when it cannot be
/// written (Goose's write_file).
pub fn write_file(p: &[u8], data: &[u8]) -> bool {
    fs::write(path(p), data).is_ok()
}

/// Replaces the file with all of `data`, or leaves it as it was: the data
/// goes to a new file beside it (its name, a tag of this write's own and
/// ".tmp"), is flushed to disk and renamed over it (Goose's
/// write_file_atomic). False, with the new file removed, when any step fails.
pub fn write_file_atomic(p: &[u8], data: &[u8]) -> bool {
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    static WRITES: AtomicU64 = AtomicU64::new(0);
    let tag = format!(".{:x}-{:x}-{:x}.tmp", std::process::id(), time_ns() as u64, WRITES.fetch_add(1, Ordering::Relaxed));
    let tmp = [p, tag.as_bytes()].concat();
    let written = match fs::OpenOptions::new().write(true).create_new(true).open(path(&tmp)) {
        Ok(mut f) => f.write_all(data).is_ok() && f.sync_all().is_ok(),
        Err(_) => return false,
    };
    if written && fs::rename(path(&tmp), path(p)).is_ok() {
        return true;
    }
    let _ = fs::remove_file(path(&tmp));
    false
}

/// Makes one folder; true if one is there afterwards (Goose's make_dir).
pub fn make_dir(p: &[u8]) -> bool {
    let _ = fs::create_dir(path(p));
    is_dir(p)
}

/// How many processors are online (native/swan_sys.c, swan_cpu_count).
pub fn cpu_count() -> i64 {
    let n = unsafe { libc::sysconf(libc::_SC_NPROCESSORS_ONLN) };
    if n > 0 {
        n as i64
    } else {
        1
    }
}

/// How many threads to work on: what this process may run on at once.
pub fn hardware_threads() -> i64 {
    std::thread::available_parallelism().map(|n| n.get() as i64).unwrap_or(1)
}

/// The absolute path of the running program (native/swan_sys.c, swan_exe_path).
pub fn exe_path() -> Option<Vec<u8>> {
    fs::read_link("/proc/self/exe").ok().map(|p| p.into_os_string().into_vec())
}

/// Starts argv in `cwd` with this process's environment, nothing to read
/// and its output and errors going to `log` (native/swan_sys.c, swan_spawn).
/// None when it could not be started.
pub fn spawn_logged(argv: &[&[u8]], cwd: &[u8], log: &[u8]) -> Option<std::process::Child> {
    use std::process::{Command, Stdio};
    let mut c = Command::new(OsStr::from_bytes(argv[0]));
    c.args(argv[1..].iter().map(|a| OsStr::from_bytes(a))).stdin(Stdio::null());
    if !cwd.is_empty() {
        c.current_dir(path(cwd));
    }
    if let Ok(f) = fs::File::create(path(log)) {
        if let Ok(g) = f.try_clone() {
            c.stdout(f).stderr(g);
        }
    }
    c.spawn().ok()
}

/// Waits for a program started by spawn_logged: its exit code, 128 + the
/// signal that ended it, or -1 (native/swan_sys.c, swan_wait_any).
pub fn wait_code(mut child: std::process::Child) -> i32 {
    use std::os::unix::process::ExitStatusExt;
    match child.wait() {
        Ok(s) => s.code().or_else(|| s.signal().map(|g| 128 + g)).unwrap_or(-1),
        Err(_) => -1,
    }
}

pub fn delete_file(p: &[u8]) -> bool {
    fs::remove_file(path(p)).is_ok()
}

pub fn rename_file(from: &[u8], to: &[u8]) -> bool {
    fs::rename(path(from), path(to)).is_ok()
}

fn strerror(code: i32) -> Vec<u8> {
    unsafe { CStr::from_ptr(libc::strerror(code)).to_bytes().to_vec() }
}

fn errno() -> i32 {
    std::io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// One pipeline/index/refresh writer owns a map at a time: an OS advisory
/// lock on a stable file beside the database. The file is kept after
/// release: unlinking it would let two writers lock two different inodes.
/// Readers use SQLite's own locks.
pub struct WriterLock {
    fd: i32,
}

impl WriterLock {
    /// Refusal comes back as the explanation.
    pub fn acquire(db_path: &[u8]) -> Result<WriterLock, Vec<u8>> {
        if db_path.is_empty() || db_path.len() >= 4096 {
            return Err(b"swan: invalid map path for writer lock".to_vec());
        }
        if is_symlink(db_path) {
            return Err(b"swan: map database symlinks are not supported for writes; use its real file path".to_vec());
        }
        // Resolve only the parent. Ownership must keep the same name while the
        // database is absent, deleted for a schema change, or atomically replaced.
        let (parent, name): (&[u8], &[u8]) = match db_path.iter().rposition(|&c| c == b'/') {
            Some(k) => (if k == 0 { b"/" } else { &db_path[..k] }, &db_path[k + 1..]),
            None => (b".", db_path),
        };
        let directory = match fs::canonicalize(path(parent)) {
            Ok(d) => d.as_os_str().as_bytes().to_vec(),
            Err(e) => {
                let mut m = b"swan: cannot resolve map directory for writer lock: ".to_vec();
                m.extend_from_slice(&strerror(e.raw_os_error().unwrap_or(0)));
                return Err(m);
            }
        };
        let mut canonical = directory;
        canonical.push(b'/');
        canonical.extend_from_slice(name);
        if canonical.len() >= 4096 {
            return Err(b"swan: map path is too long for writer lock".to_vec());
        }
        let mut lock_path = canonical.clone();
        lock_path.extend_from_slice(b".lock");
        let c = match CString::new(lock_path) {
            Ok(c) => c,
            Err(_) => return Err(b"swan: invalid map path for writer lock".to_vec()),
        };
        // Refuse a symlink at the lock entry atomically, including dangling links.
        // Parent aliases remain supported through the canonical directory above.
        // Not close-on-exec: indexers started under the lock inherit it, so
        // killing Swan cannot release ownership while they still write.
        let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDWR | libc::O_CREAT | libc::O_NOFOLLOW, 0o666 as libc::c_uint) };
        if fd < 0 {
            let mut m = b"swan: cannot open map writer lock: ".to_vec();
            m.extend_from_slice(&strerror(errno()));
            return Err(m);
        }
        if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let cause = errno();
            unsafe { libc::close(fd) };
            let mut m: Vec<u8>;
            if cause == libc::EWOULDBLOCK || cause == libc::EAGAIN {
                m = b"swan: another writer is in progress for ".to_vec();
                m.extend_from_slice(&canonical);
                m.extend_from_slice(b"; retry after it finishes");
            } else {
                m = b"swan: cannot acquire map writer lock: ".to_vec();
                m.extend_from_slice(&strerror(cause));
            }
            return Err(m);
        }
        Ok(WriterLock { fd })
    }

    /// Success only: all foreground jobs and publication have completed.
    /// Idle build servers may retain copies of this open file description,
    /// so the lock is released, not just the descriptor closed.
    pub fn complete(self) {
        unsafe {
            while libc::flock(self.fd, libc::LOCK_UN) != 0 && errno() == libc::EINTR {}
            libc::close(self.fd);
        }
    }
}

/// An environment variable's value; empty when unset.
pub fn env(name: &[u8]) -> Vec<u8> {
    std::env::var_os(OsStr::from_bytes(name)).map(|v| v.into_vec()).unwrap_or_default()
}

/// Goose's write_stderr: the bytes as they are, no line end added.
pub fn write_stderr(text: &[u8]) {
    use std::io::Write;
    let _ = std::io::stderr().write_all(text);
}

/// The real path, links and "." and ".." worked out (realpath(3)); None
/// when it does not exist.
pub fn realpath(p: &[u8]) -> Option<Vec<u8>> {
    fs::canonicalize(path(p)).ok().map(|d| d.into_os_string().into_vec())
}

/// Runs argv in `cwd` with this process's environment and stdin closed, in
/// a process group of its own, as swan_run does (native/swan_sys.c): one
/// deadline of `timeout_ms` holds for its output and its exit, even after
/// the program exits while a child of it keeps the output open, and the
/// whole group is killed at it. Some((exit code, or 128 + signal; stdout))
/// when it ran to the end; None when it could not be started or was killed.
/// Stage 2 needs only `rustup show home`; the full swan_run (environment
/// entries, standard error, sealing) comes with the map at stage 4.
pub fn run_capture(argv: &[&[u8]], cwd: &[u8], timeout_ms: u64) -> Option<(i32, Vec<u8>)> {
    use std::io::Read;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let (first, rest) = argv.split_first()?;
    let mut child = Command::new(OsStr::from_bytes(first))
        .args(rest.iter().map(|a| OsStr::from_bytes(a)))
        .current_dir(path(cwd))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let group = child.id() as i32;
    let kill = |child: &mut Child| {
        unsafe { libc::kill(-group, libc::SIGKILL) };
        let _ = child.wait();
    };
    let Some(mut stdout) = child.stdout.take() else {
        kill(&mut child);
        return None;
    };
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut o = Vec::new();
        let _ = stdout.read_to_end(&mut o);
        let _ = tx.send(o);
    });
    // The output, until every process holding it closes it.
    let out = match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(o) => o,
        Err(_) => {
            kill(&mut child);
            return None;
        }
    };
    // Then the program itself, which may still run with its output closed.
    loop {
        match child.try_wait() {
            Ok(Some(s)) => return Some((s.code().or(s.signal().map(|n| 128 + n)).unwrap_or(-1), out)),
            Ok(None) if Instant::now() >= deadline => {
                kill(&mut child);
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(5)),
            Err(_) => {
                kill(&mut child);
                return None;
            }
        }
    }
}

/// Runs argv (argv[0] looked up on the PATH the program itself will have)
/// in `cwd` (empty: this process's), with `env` entries ("NAME=value") set
/// over this process's environment, nothing to read, and a process group of
/// its own. Appends what it writes to `out` and `err`. Returns its exit
/// code, 128 + the signal that ended it, 127 when it could not be started
/// (the reason goes to `err`), or -2 after killing its whole group at
/// `timeout_ms` (0: no deadline). The deadline holds for its output and for
/// its exit, even when it exits and a child of it keeps the output open
/// (native/swan_sys.c, swan_run).
pub fn run(argv: &[&[u8]], cwd: &[u8], env: &[&[u8]], timeout_ms: i64, out: &mut Vec<u8>, err: &mut Vec<u8>) -> i32 {
    use std::os::unix::io::AsRawFd;
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let Some((first, rest)) = argv.split_first() else {
        err.extend_from_slice(b"swan_run: cannot start");
        return -1;
    };
    // The program swan_run starts says these two itself, on the way out
    // with 127, before it becomes argv[0]; here the same words are written
    // for it.
    if !cwd.is_empty() {
        let seen = fs::metadata(path(cwd)).map_err(|e| e.raw_os_error().unwrap_or(libc::ENOENT)).and_then(|m| if m.is_dir() { Ok(()) } else { Err(libc::ENOTDIR) });
        if let Err(code) = seen {
            err.extend_from_slice(b"chdir: ");
            err.extend_from_slice(&strerror(code));
            err.push(b'\n');
            return 127;
        }
    }
    // Where argv[0] may be: itself when it names a folder, else each folder
    // of the PATH the program will have (an entry of `env`, else this
    // process's), tried in order until one starts, as swan_run does.
    let mut places: Vec<Vec<u8>> = Vec::new();
    if first.contains(&b'/') {
        places.push(first.to_vec());
    } else {
        let ours = env.iter().find(|e| e.starts_with(b"PATH=")).map(|e| e[5..].to_vec());
        let dirs = ours.or_else(|| std::env::var_os("PATH").map(|v| v.into_vec())).unwrap_or_default();
        if !dirs.is_empty() {
            for dir in dirs.split(|&b| b == b':') {
                if dir.len() + first.len() + 2 < 4096 {
                    places.push([dir, b"/", first].concat());
                }
            }
        }
    }
    let mut child = None;
    let mut why = libc::ENOENT;
    for place in &places {
        let mut c = Command::new(OsStr::from_bytes(place));
        c.arg0(OsStr::from_bytes(first)).args(rest.iter().map(|a| OsStr::from_bytes(a)));
        c.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
        if !cwd.is_empty() {
            c.current_dir(path(cwd));
        }
        for e in env {
            if let Some(eq) = e.iter().position(|&b| b == b'=') {
                c.env(OsStr::from_bytes(&e[..eq]), OsStr::from_bytes(&e[eq + 1..]));
            }
        }
        match c.spawn() {
            Ok(started) => {
                child = Some(started);
                break;
            }
            Err(e) => why = e.raw_os_error().unwrap_or(libc::ENOENT),
        }
    }
    let Some(mut child) = child else {
        err.extend_from_slice(b"swan_run: cannot run ");
        err.extend_from_slice(first);
        err.extend_from_slice(b": ");
        err.extend_from_slice(&strerror(why));
        err.push(b'\n');
        return 127;
    };
    let group = child.id() as i32;
    let deadline = if timeout_ms > 0 { Some(Instant::now() + Duration::from_millis(timeout_ms as u64)) } else { None };
    // Kept until the end: dropping one closes it.
    let streams = (child.stdout.take(), child.stderr.take());
    let mut fds = [
        libc::pollfd { fd: streams.0.as_ref().map_or(-1, |s| s.as_raw_fd()), events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: streams.1.as_ref().map_or(-1, |s| s.as_raw_fd()), events: libc::POLLIN, revents: 0 },
    ];
    let mut open_fds = fds.iter().filter(|f| f.fd >= 0).count();
    let mut timed_out = false;
    let mut buf = vec![0u8; 65536];
    while open_fds > 0 {
        let mut wait: i32 = -1;
        if let Some(d) = deadline {
            let left = d.saturating_duration_since(Instant::now());
            if left.is_zero() {
                timed_out = true;
                break;
            }
            wait = left.as_millis().clamp(1, i32::MAX as u128) as i32;
        }
        let r = unsafe { libc::poll(fds.as_mut_ptr(), 2, wait) };
        if r < 0 {
            if errno() == libc::EINTR {
                continue;
            }
            break;
        }
        for (i, f) in fds.iter_mut().enumerate() {
            if f.fd < 0 || (f.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR)) == 0 {
                continue;
            }
            let n = unsafe { libc::read(f.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n > 0 {
                (if i == 0 { &mut *out } else { &mut *err }).extend_from_slice(&buf[..n as usize]);
            } else {
                f.fd = -1; // closed below, with its stream
                open_fds -= 1;
            }
        }
    }
    // Both streams can close while the program keeps running (it redirected
    // them, or handed them to a child): the deadline still holds.
    let mut status = None;
    while !timed_out {
        match child.try_wait() {
            Ok(Some(s)) => {
                status = Some(s);
                break;
            }
            Ok(None) => {}
            Err(_) => break,
        }
        match deadline {
            Some(d) if Instant::now() >= d => timed_out = true,
            Some(_) => std::thread::sleep(Duration::from_millis(20)),
            None => break,
        }
    }
    if timed_out {
        unsafe { libc::kill(-group, libc::SIGKILL) };
    }
    drop(streams);
    let status = match status {
        Some(s) => Some(s),
        None => child.wait().ok(),
    };
    if timed_out {
        return -2;
    }
    match status {
        Some(s) => s.code().or_else(|| s.signal().map(|g| 128 + g)).unwrap_or(-1),
        None => -1,
    }
}

/// A file's size in bytes (stat(2), links followed), or -1
/// (native/swan_sys.c, swan_file_size).
pub fn file_size(p: &[u8]) -> i64 {
    if p.is_empty() || p.len() >= 4096 {
        return -1;
    }
    fs::metadata(path(p)).map(|m| m.len() as i64).unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::run_capture;

    #[test]
    fn run_capture_gives_the_output_and_the_exit_code() {
        assert_eq!(run_capture(&[b"sh", b"-c", b"echo hi; exit 3"], b"/", 10000), Some((3, b"hi\n".to_vec())));
    }

    // A program that exits but leaves a child holding its output: the
    // deadline still holds, as in swan_run (Macroscope, on #75).
    #[test]
    fn run_capture_keeps_its_deadline_after_the_program_exits() {
        let t = std::time::Instant::now();
        let got = run_capture(&[b"sh", b"-c", b"sleep 30 & echo hi"], b"/", 500);
        assert!(t.elapsed().as_secs() < 5, "took {:?}", t.elapsed());
        assert_eq!(got, None);
    }
}
