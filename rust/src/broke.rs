// swan broke <out-dir> <file>...: for the files just written, the errors their
// language servers report now that they did not report the last time this
// was asked. Made to run after every edit (scripts/hooks/what-broke-after-edit.py
// runs it and reads its JSON), so an agent hears of a break when it makes it
// and is not told again of errors that were already there. The files are
// relative to the map's repo, or absolute inside it.
//
// What was seen is kept beside the map in broke-seen.tsv, as the Goose
// program keeps it (src/broke.goose), one "file<TAB>severity|code|message"
// per line, a line with an empty key for a file looked at, and one
// "file<TAB>not-asked|reason|" line for a file not asked (other than
// no_server) so hooks report it once per reason. Lines move as code is
// edited, so an error is the same one when its file, code and message are;
// a second error just like one already there is not new.
//
// Unlike the Goose program: the files are asked about by language, one
// server per language in turn, so a language that cannot be asked does not
// hide another's errors. A file not asked (no server, not trusted, not
// settled, failed) says why and keeps its earlier error lines; when its
// reason is not no_server and the file is in the repo with no tab or newline
// in its name, it records one not-asked line until the reason changes or the
// file is asked again. The seen file is read, compared and written under a
// lock taken once the servers have answered, so two hooks at once do not
// lose each other's lines.
//
// Exit: 0 every file asked and nothing new; 1 new errors; 2 usage, or no
// map; 3 nothing new, but a file could not be asked.

use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::time::Instant;

use serde::Serialize;

use crate::db::Db;
use crate::live::{budget, file_in, Diag, Diagnosed, Live, Reason, Refusal};
use crate::modules::{language_of, Entry};
use crate::query::meta_value;
use crate::sys;
use crate::walk::Walk;

const NOTE: &str = "new_errors are errors the language server reports now and did not when this was last asked for the file; on a first look every error counts as new; when asked is false (except no_server), first_time is true the first time the file was not asked for that reason, and false until the reason changes or the file is asked again";

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
    NotAsked {
        relative_path: String,
        asked: bool,
        reason: &'static str,
        #[serde(skip_serializing_if = "Option::is_none")]
        first_time: Option<bool>,
        why: String,
    },
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
type Answer = Result<Vec<Diag>, Refusal>;

struct Answered {
    name: Vec<u8>,
    in_repo: bool,
    answer: Answer,
}

pub struct BrokeOutcome {
    pub json: Vec<u8>,
    pub new_errors: usize,
    pub asked: usize,
    pub not_asked: usize,
}

// Runs `what_broke` for `args` against a map folder `out_arg` and repo `root`.
// Returns the JSON report and counts, or an explanation when the map folder or
// repo is missing.
pub fn what_broke(out_arg: &[u8], root: &[u8], args: &[Vec<u8>]) -> Result<BrokeOutcome, Vec<u8>> {
    let deadline = Instant::now() + budget();
    let Some(out) = sys::realpath(out_arg).filter(|o| sys::is_dir(o)) else {
        return Err(format!("no such folder: {}", lossy(out_arg)).into_bytes());
    };
    let Some(repo) = sys::realpath(root).filter(|r| !root.is_empty() && sys::is_dir(r)) else {
        return Err(format!("the map's repo is not there ({}); rebuild the map with swan map", lossy(root)).into_bytes());
    };

    // Each file once, as its path from the repo, or why it cannot be asked.
    let mut files: Vec<(Vec<u8>, bool, Option<Answer>)> = Vec::new();
    for arg in args {
        match file_in(&repo, arg) {
            Ok(rel) if files.iter().any(|(f, in_repo, _)| *in_repo && *f == rel) => {}
            Ok(rel) => files.push((rel, true, None)),
            Err(why) => files.push((arg.clone(), false, Some(Err(Refusal { reason: Reason::Failed, why })))),
        }
    }
    // By language, in the order the files came.
    let mut langs: Vec<(String, Entry, Vec<usize>)> = Vec::new();
    for (i, (rel, _, answer)) in files.iter_mut().enumerate() {
        if answer.is_some() {
            continue;
        }
        match language_of(rel) {
            Ok(Some((lang, entry))) => match langs.iter_mut().find(|(l, _, _)| *l == lang) {
                Some((_, _, of)) => of.push(i),
                None => langs.push((lang, entry, vec![i])),
            },
            Ok(None) => *answer = Some(Err(Refusal { reason: Reason::NoServer, why: format!("no live server for {}", lossy(rel)) })),
            Err(why) => *answer = Some(Err(Refusal { reason: Reason::Failed, why: lossy(&why) })),
        }
    }
    let mut walk = Walk::default();
    walk.load(&repo, &out);
    for (lang, entry, of) in &langs {
        match Live::start(&walk, &repo, &out, lang, entry, deadline) {
            Ok(mut live) => {
                for &i in of {
                    files[i].2 = Some(match live.diagnostics(&files[i].0) {
                        Ok(Diagnosed::Settled(items)) => Ok(items),
                        Ok(Diagnosed::Unsettled(why)) => Err(Refusal { reason: Reason::Unsettled, why }),
                        Err(why) => Err(Refusal { reason: Reason::Failed, why }),
                    });
                }
                live.stop();
            }
            Err(refusal) => {
                for &i in of {
                    files[i].2 = Some(Err(refusal.clone()));
                }
            }
        }
    }
    let answered: Vec<Answered> = files
        .into_iter()
        .map(|(name, in_repo, a)| Answered { name, in_repo, answer: a.unwrap_or_else(|| Err(Refusal { reason: Reason::Failed, why: "not asked".to_string() })) })
        .collect();
    let asked = answered.iter().filter(|a| a.answer.is_ok()).count();
    let not_asked = answered.len() - asked;
    let report = remember(&out, &answered);
    let json = serde_json::to_string(&report).unwrap_or_default().into_bytes();
    Ok(BrokeOutcome { json, new_errors: report.new_errors, asked, not_asked })
}

pub fn broke_main(out_arg: &[u8], args: &[Vec<u8>]) -> i32 {
    let Some(out) = sys::realpath(out_arg).filter(|o| sys::is_dir(o)) else { return refuse(&format!("no such folder: {}", lossy(out_arg))) };
    let db_path = [&out[..], b"/swan.db"].concat();
    let root = match sys::file_exists(&db_path).then(|| Db::open_existing(&db_path)) {
        Some(Ok(db)) => meta_value(&db, b"root"),
        _ => return refuse(&format!("no map at {}", lossy(&db_path))),
    };
    let outcome = match what_broke(&out, &root, args) {
        Ok(o) => o,
        Err(why) => return refuse(&lossy(&why)),
    };
    crate::util::print(&outcome.json);
    if outcome.new_errors > 0 {
        1
    } else if outcome.not_asked > 0 {
        3
    } else {
        0
    }
}

fn remember_refusal(a: &Answered, reason: Reason) -> bool {
    reason != Reason::NoServer && a.in_repo && !a.name.iter().any(|&c| c == b'\t' || c == b'\n')
}

// Compares what the asked files show with what was seen, keeps what they
// show now, and records one not-asked line per file and reason for
// remembered refusals while keeping any earlier error lines on those files.
// When nothing is asked or remembered, the map folder is not written to.
fn remember(out: &[u8], answered: &[Answered]) -> Report {
    let writes = answered.iter().any(|a| match &a.answer {
        Ok(_) => true,
        Err(r) => remember_refusal(a, r.reason),
    });
    let _held = writes.then(|| lock(out));
    let seen_path = [out, b"/broke-seen.tsv"].concat();
    let mut seen = Vec::new();
    if writes {
        sys::read_file(&seen_path, &mut seen);
    }
    let seen_lines: HashSet<&[u8]> = seen.split(|&c| c == b'\n').filter(|l| !l.is_empty()).collect();
    let mut now: Vec<u8> = Vec::new();
    let mut not_asked_now: Vec<u8> = Vec::new();
    let mut asked: HashSet<&[u8]> = HashSet::new();
    let mut not_asked_replace: HashSet<&[u8]> = HashSet::new();
    let mut report = Report { new_errors: 0, files: Vec::new(), note: NOTE };
    for entry in answered {
        let rel = &entry.name;
        let relative_path = lossy(rel);
        let items = match &entry.answer {
            Ok(items) => items,
            Err(r) => {
                let first_time = if remember_refusal(entry, r.reason) {
                    let line = [&rel[..], b"\tnot-asked|", r.reason.as_str().as_bytes(), b"|"].concat();
                    let is_first = !seen_lines.contains(&line[..]);
                    if is_first {
                        not_asked_replace.insert(rel);
                        not_asked_now.extend_from_slice(&line);
                        not_asked_now.push(b'\n');
                    }
                    Some(is_first)
                } else {
                    None
                };
                report.files.push(FileReport::NotAsked { relative_path, asked: false, reason: r.reason.as_str(), first_time, why: r.why.clone() });
                continue;
            }
        };
        asked.insert(rel);
        let prefix = [&rel[..], b"\t"].concat();
        let na_prefix = [&rel[..], b"\tnot-asked|"].concat();
        let first_look = !seen_lines.iter().any(|l| l.starts_with(&prefix) && !l.starts_with(&na_prefix));
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
    if writes {
        let mut keep: Vec<u8> = Vec::new();
        for l in seen.split(|&c| c == b'\n').filter(|l| !l.is_empty()) {
            let drop = match l.iter().position(|&c| c == b'\t') {
                Some(t) => {
                    let f = &l[..t];
                    asked.contains(f) || (l[t + 1..].starts_with(b"not-asked|") && not_asked_replace.contains(f))
                }
                None => false,
            };
            if !drop {
                keep.extend_from_slice(l);
                keep.push(b'\n');
            }
        }
        keep.extend_from_slice(&now);
        keep.extend_from_slice(&not_asked_now);
        if keep != seen {
            sys::write_file_atomic(&seen_path, &keep);
        }
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
