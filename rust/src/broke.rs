// swan broke <out-dir> <file>...: for the files just written, the errors their
// language servers report now that they did not report the last time this
// was asked. Made to run after every edit (scripts/hooks/what-broke-after-edit.py
// runs it and reads its JSON), so an agent hears of a break when it makes it
// and is not told again of errors that were already there. The files are
// relative to the map's repo, or absolute inside it.
//
// What was seen is kept beside the map in broke-seen.tsv, as the Goose
// program keeps it (src/broke.goose), one "file<TAB>severity|code|message"
// per line, and a line with an empty key for a file looked at. Lines move as
// code is edited, so an error is the same one when its file, code and
// message are; a second error just like one already there is not new.
//
// Unlike the Goose program: the files are asked about by language, one
// server per language in turn, so a language that cannot be asked does not
// hide another's errors. A file not asked (no server, not trusted, not
// settled, out of time) says why, and its lines in the seen file stay as
// they were. The seen file is read, compared and written under a lock taken
// once the servers have answered, so two hooks at once do not lose each
// other's lines.
//
// Exit: 0 every file asked and nothing new; 1 new errors; 2 usage, or no
// map; 3 nothing new, but a file could not be asked.

use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::time::Instant;

use serde::Serialize;

use crate::db::Db;
use crate::live::{budget, file_in, Diag, Diagnosed, Live};
use crate::modules::{language_of, Entry};
use crate::query::meta_value;
use crate::sys;
use crate::walk::Walk;

const NOTE: &str = "new_errors are errors the language server reports now and did not when this was last asked for the file; on a first look every error counts as new";

#[derive(Serialize)]
struct Report {
    new_errors: usize,
    files: Vec<FileReport>,
    note: &'static str,
}

#[derive(Serialize)]
#[serde(untagged)]
enum FileReport {
    Asked { relative_path: String, asked: bool, first_look: bool, new_errors: Vec<NewError>, errors_already_there: usize, warnings: usize },
    NotAsked { relative_path: String, asked: bool, why: String },
}

#[derive(Serialize)]
struct NewError {
    line: u64,
    col: u64,
    message: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    code: String,
}

/// What a file's server said, or why it was not asked.
type Answer = Result<Vec<Diag>, String>;

pub fn broke_main(out_arg: &[u8], args: &[Vec<u8>]) -> i32 {
    let deadline = Instant::now() + budget();
    let Some(out) = sys::realpath(out_arg).filter(|o| sys::is_dir(o)) else { return refuse(&format!("no such folder: {}", lossy(out_arg))) };
    let db_path = [&out[..], b"/swan.db"].concat();
    let root = match sys::file_exists(&db_path).then(|| Db::open_existing(&db_path)) {
        Some(Ok(db)) => meta_value(&db, b"root"),
        _ => return refuse(&format!("no map at {}", lossy(&db_path))),
    };
    let Some(repo) = sys::realpath(&root).filter(|r| !root.is_empty() && sys::is_dir(r)) else {
        return refuse(&format!("the map's repo is not there ({}); rebuild the map with swan map", lossy(&root)));
    };

    // Each file once, as its path from the repo, or why it cannot be asked.
    let mut files: Vec<(Vec<u8>, Option<Answer>)> = Vec::new();
    for arg in args {
        match file_in(&repo, arg) {
            Ok(rel) if files.iter().any(|(f, _)| *f == rel) => {}
            Ok(rel) => files.push((rel, None)),
            Err(why) => files.push((arg.clone(), Some(Err(why)))),
        }
    }
    // By language, in the order the files came.
    let mut langs: Vec<(String, Entry, Vec<usize>)> = Vec::new();
    for (i, (rel, answer)) in files.iter_mut().enumerate() {
        if answer.is_some() {
            continue;
        }
        match language_of(rel) {
            Ok(Some((lang, entry))) => match langs.iter_mut().find(|(l, _, _)| *l == lang) {
                Some((_, _, of)) => of.push(i),
                None => langs.push((lang, entry, vec![i])),
            },
            Ok(None) => *answer = Some(Err(format!("no live server for {}", lossy(rel)))),
            Err(why) => *answer = Some(Err(lossy(&why))),
        }
    }
    let mut walk = Walk::default();
    walk.load(&repo, &out);
    for (lang, entry, of) in &langs {
        match Live::start(&walk, &repo, &out, lang, entry, deadline) {
            Ok(mut live) => {
                for &i in of {
                    files[i].1 = Some(match live.diagnostics(&files[i].0) {
                        Ok(Diagnosed::Settled(items)) => Ok(items),
                        Ok(Diagnosed::Unsettled(why)) => Err(why),
                        Err(why) => Err(why),
                    });
                }
                live.stop();
            }
            Err(why) => {
                for &i in of {
                    files[i].1 = Some(Err(why.clone()));
                }
            }
        }
    }
    let answered: Vec<(Vec<u8>, Answer)> = files.into_iter().map(|(f, a)| (f, a.unwrap_or_else(|| Err("not asked".to_string())))).collect();
    let report = remember(&out, &answered);
    crate::util::print(serde_json::to_string(&report).unwrap_or_default().as_bytes());
    if report.new_errors > 0 {
        1
    } else if answered.iter().any(|(_, a)| a.is_err()) {
        3
    } else {
        0
    }
}

// Compares what the asked files show with what was seen, and keeps what they
// show now; the lines of every other file stay as they were. When no file
// was asked nothing is kept, and the map folder is not written to.
fn remember(out: &[u8], answered: &[(Vec<u8>, Answer)]) -> Report {
    let _held = answered.iter().any(|(_, a)| a.is_ok()).then(|| lock(out));
    let seen_path = [out, b"/broke-seen.tsv"].concat();
    let mut seen = Vec::new();
    sys::read_file(&seen_path, &mut seen);
    let seen_lines: HashSet<&[u8]> = seen.split(|&c| c == b'\n').filter(|l| !l.is_empty()).collect();
    let mut now: Vec<u8> = Vec::new();
    let mut asked: HashSet<&[u8]> = HashSet::new();
    let mut report = Report { new_errors: 0, files: Vec::new(), note: NOTE };
    for (rel, answer) in answered {
        let relative_path = lossy(rel);
        let items = match answer {
            Ok(items) => items,
            Err(why) => {
                report.files.push(FileReport::NotAsked { relative_path, asked: false, why: why.clone() });
                continue;
            }
        };
        asked.insert(rel);
        let prefix = [&rel[..], b"\t"].concat();
        let first_look = !seen_lines.iter().any(|l| l.starts_with(&prefix));
        now.extend_from_slice(&prefix);
        now.push(b'\n');
        let (mut new_errors, mut still, mut warnings) = (Vec::new(), 0, 0);
        for d in items {
            if d.severity != "error" {
                warnings += 1;
                continue;
            }
            let line = [&prefix[..], &key(d)].concat();
            if seen_lines.contains(&line[..]) {
                still += 1;
            } else {
                new_errors.push(NewError { line: d.line, col: d.col, message: d.message.clone(), code: d.code.clone() });
            }
            now.extend_from_slice(&line);
            now.push(b'\n');
        }
        report.new_errors += new_errors.len();
        report.files.push(FileReport::Asked { relative_path, asked: true, first_look, new_errors, errors_already_there: still, warnings });
    }
    if !asked.is_empty() {
        let mut keep: Vec<u8> = Vec::new();
        for l in seen.split(|&c| c == b'\n').filter(|l| !l.is_empty()) {
            let file = l.iter().position(|&c| c == b'\t').map(|t| &l[..t]);
            if !file.is_some_and(|f| asked.contains(f)) {
                keep.extend_from_slice(l);
                keep.push(b'\n');
            }
        }
        keep.extend_from_slice(&now);
        sys::write_file_atomic(&seen_path, &keep);
    }
    report
}

// "severity|code|message", the message on one line.
fn key(d: &Diag) -> Vec<u8> {
    let message: String = d.message.chars().map(|c| if c == '\n' || c == '\t' { ' ' } else { c }).collect();
    format!("{}|{}|{message}", d.severity, d.code).into_bytes()
}

// The seen file's lock, held until dropped: a file of its own beside it, as
// the seen file is replaced whole and a lock on it would stay with the old
// one. None when it cannot be taken; the seen file is then written unlocked.
fn lock(out: &[u8]) -> Option<File> {
    let f = OpenOptions::new().create(true).truncate(false).write(true).open(sys::path(&[out, b"/broke-seen.lock"].concat())).ok()?;
    loop {
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Some(f);
        }
        if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return None;
        }
    }
}

fn refuse(why: &str) -> i32 {
    sys::write_stderr(format!("swan broke: {why}\n").as_bytes());
    2
}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}
