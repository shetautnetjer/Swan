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
