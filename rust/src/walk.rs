// Walking a repo's files: which folders a walk leaves out, and the walk.
// Carried over from the head of src/pipeline.goose; the rest of that file
// (the map itself) is stage 4.

use crate::seal::sealed_run;
use crate::sys;
use crate::util::{contains_line, push_int, starts_with};

const SKIP_DIRS: [&[u8]; 13] = [
    b"node_modules",
    b".git",
    b"target",
    b".venv",
    b"venv",
    b"__pycache__",
    b".tox",
    b".mypy_cache",
    b".pytest_cache",
    b".swan",
    b"build",
    b".gradle",
    b"obj",
];

// The folders of a repo that git ignores (its .gitignore files and
// .git/info/exclude), as paths from the repo, one per line: build output,
// caches, a test run's leftovers. They are not the repo's code, and no walk
// of the repo enters them. A file git tracks is never in such a folder: git
// lists a folder as ignored only when nothing in it is tracked.
//
// `swan map` asks git at its start and keeps the answer in the map folder,
// git-ignored.txt, where the map's other processes and later questions read
// it (load). Fixed room, as in the Goose program: a list that outgrows it is
// cut at a line and the folders past the cut are walked as before.
#[derive(Default)]
pub struct Walk {
    ignored: Vec<u8>,
    repo: Vec<u8>,
}

impl Walk {
    pub fn set(&mut self, repo: &[u8], lines: &[u8]) {
        self.ignored.clear();
        self.repo.clear();
        if !(!repo.is_empty() && repo.len() < 4000) {
            return;
        }
        self.repo.extend_from_slice(repo);
        for line in lines.split(|&c| c == b'\n') {
            if !line.is_empty() && self.ignored.len() + line.len() + 1 < 65000 {
                self.ignored.extend_from_slice(line);
                self.ignored.push(b'\n');
            }
        }
    }

    // For a process that walks a repo whose map folder is `map_dir`.
    pub fn load(&mut self, repo: &[u8], map_dir: &[u8]) {
        let mut lines: Vec<u8> = Vec::new();
        sys::read_file(&[map_dir, b"/git-ignored.txt"].concat(), &mut lines);
        self.set(repo, &lines);
    }

    // Asks git which folders it ignores and keeps the answer for this map.
    // Sealed like every other step: git reads the repo's own config.
    // Folders a walk skips anyway (hidden ones, node_modules, target, ...)
    // are left out of the list. `said` gets a line for the report when the
    // list is not empty.
    pub fn refresh(&mut self, repo: &[u8], out: &[u8], trusted: bool, said: &mut Vec<u8>) {
        let mut list: Vec<u8> = Vec::new();
        let mut all: Vec<u8> = Vec::new();
        if sys::is_dir(&[repo, b"/.git"].concat()) || sys::file_exists(&[repo, b"/.git"].concat()) {
            let argv: [&[u8]; 8] = [b"git", b"-c", b"core.fsmonitor=false", b"ls-files", b"-z", b"--others", b"--ignored", b"--exclude-standard"];
            let mut argv = argv.to_vec();
            argv.push(b"--directory");
            let mut o: Vec<u8> = Vec::new();
            let mut e: Vec<u8> = Vec::new();
            if sealed_run(&argv, repo, out, trusted, &[], 60000, &mut o, &mut e) == 0 {
                for entry in o.split(|&c| c == 0) {
                    if !(entry.len() > 1 && entry[entry.len() - 1] == b'/') {
                        continue;
                    }
                    let dir = &entry[..entry.len() - 1];
                    all.extend_from_slice(dir);
                    all.push(b'\n');
                    // would a walk reach it, were it not ignored
                    let walked = !dir.split(|&c| c == b'/').any(|seg| seg.is_empty() || seg[0] == b'.' || SKIP_DIRS.contains(&seg));
                    if walked {
                        list.extend_from_slice(dir);
                        list.push(b'\n');
                    }
                }
            }
        }
        sys::write_file(&[out, b"/git-ignored.txt"].concat(), &list);
        // Every ignored folder, the ones no walk enters included, for the
        // flattener: an indexer follows includes and imports wherever they lead
        // (Swan's C fixtures pulled 22 compiler headers out of its .tools).
        sys::write_file(&[out, b"/git-ignored-all.txt"].concat(), &all);
        self.set(repo, &list);
        let n = list.iter().filter(|&&c| c == b'\n').count();
        if n > 0 {
            said.extend_from_slice(b"not mapped, git ignores ");
            said.extend_from_slice(if n == 1 { b"this folder" } else { b"these folders" });
            said.push(b':');
            for d in list.split(|&c| c == b'\n').filter(|d| !d.is_empty()).take(6) {
                said.push(b' ');
                said.extend_from_slice(d);
            }
            if n > 6 {
                said.extend_from_slice(b" and ");
                push_int(said, n as i64 - 6);
                said.extend_from_slice(b" more");
            }
            said.push(b'\n');
        }
    }

    // Whether a walk leaves this folder out.
    pub fn skips(&self, full: &[u8]) -> bool {
        let r = &self.repo[..];
        if !(!self.ignored.is_empty() && full.len() > r.len() + 1 && starts_with(full, r) && full[r.len()] == b'/') {
            return false;
        }
        contains_line(&self.ignored, &full[r.len() + 1..])
    }

    // f(path, name) for each file under repo, breadth-first, skipping folders
    // that hold dependencies, caches or build output. A symlinked folder is not
    // entered: it could lead out of the repo or loop back into it (a link to "."
    // listed one file 41 times), and a target inside the repo is walked under
    // its own path anyway.
    pub fn each_file(&self, repo: &[u8], mut f: impl FnMut(&[u8], &[u8])) {
        let mut dirs: Vec<Vec<u8>> = vec![repo.to_vec()]; // only grows; `next` walks it
        let mut next = 0;
        let mut seen = 0;
        while next < dirs.len() && seen < 200000 {
            let dir = dirs[next].clone();
            next += 1;
            let names = match sys::list_dir(&dir) {
                Some(n) => n,
                None => continue,
            };
            for name in names {
                if name.is_empty() {
                    continue;
                }
                seen += 1;
                let full = [&dir[..], b"/", &name[..]].concat();
                if sys::is_dir(&full) {
                    // Hidden folders (.git, .venv, .tools, .cache, .github) hold tooling
                    // and caches, not the repo's code: Swan's own .tools is 3.7 GB of
                    // fetched compilers, and walking it made its map take over ten
                    // minutes.
                    if name[0] != b'.' && !SKIP_DIRS.contains(&&name[..]) && !sys::is_symlink(&full) && !self.skips(&full) {
                        dirs.push(full);
                    }
                } else {
                    f(&full, &name);
                }
            }
        }
    }
}
