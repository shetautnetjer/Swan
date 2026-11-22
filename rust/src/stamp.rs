// Content stamps: one line per source file (size, time, hash, code spans),
// computed in worker processes or threads, one per core, and kept in
// content-stamps.tsv so unchanged files are not read again.
//
// Carried over from src/stamp.goose. The workers on threads share one list
// of files where the Goose program's take theirs from a queue; either way
// the lines come back in the order the workers finish them.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Instant;

use crate::change::{code_hash, cosmetic_lang, line_of_path};
use crate::sys;
use crate::util::{hash, parse_int, print, push_int, split};
use crate::walk::Walk;

// Whether content-stamps.tsv already holds this file's stamp (same size and
// mtime), so the map's `stamp` would not read it.
fn stamp_known(prev: &[u8], prev_at: &HashMap<u64, usize>, rel: &[u8], full: &[u8]) -> bool {
    let line = line_of_path(prev, prev_at, rel);
    if line.is_empty() {
        return false;
    }
    let f = split(line, b'\t');
    f.len() == 6 && f[1] == sys::file_size(full).to_string().as_bytes() && f[2] == sys::mtime_ns(full).to_string().as_bytes()
}

// How many stamp workers to start: $SWAN_STAMP_JOBS, else every core, at
// most 32. 1 stamps in this process, as before.
fn stamp_jobs() -> i64 {
    if let Some(n) = parse_int(&sys::env(b"SWAN_STAMP_JOBS")) {
        if n > 0 {
            return n;
        }
    }
    sys::cpu_count().clamp(1, 32)
}

fn ms_since(t0: Instant) -> i64 {
    (t0.elapsed().as_secs_f64() * 1000.0) as i64
}

fn part_path(out: &[u8], what: &[u8], w: i64, ext: &[u8]) -> Vec<u8> {
    let mut p = [out, b"/", what].concat();
    push_int(&mut p, w);
    p.extend_from_slice(ext);
    p
}

// A first map parses every TypeScript, JavaScript and Python file to stamp
// its code (src/change.rs), one after another: 6.6 s on rea. This stamps
// the files content-stamps.tsv does not already hold in `swan stamp-worker`
// processes, one per core, and leaves their lines in `pre`. The workers run
// the same code (stamp_line), so a stamp is the same whichever process made
// it; a worker that fails leaves its files to be stamped here.
#[allow(clippy::too_many_arguments)]
pub fn prestamp(walk: &Walk, repo: &[u8], out: &[u8], texts_dir: &[u8], prev: &[u8], prev_at: &HashMap<u64, usize>, pre: &mut Vec<u8>, report: &mut Vec<u8>) {
    let k_max = stamp_jobs();
    if k_max <= 1 {
        return;
    }
    let mut todo: Vec<u8> = Vec::new(); // relative paths, one per line
    let mut n: i64 = 0;
    walk.each_file(repo, |full, name| {
        if cosmetic_lang(name).is_empty() {
            return;
        }
        let rel = &full[repo.len() + 1..];
        if stamp_known(prev, prev_at, rel, full) {
            return;
        }
        todo.extend_from_slice(rel);
        todo.push(b'\n');
        n += 1;
    });
    // Below a few hundred files starting processes costs more than it saves.
    let mut min_files: i64 = 256;
    if let Some(m) = parse_int(&sys::env(b"SWAN_STAMP_MIN")) {
        if m > 0 {
            min_files = m;
        }
    }
    if n < min_files {
        return;
    }
    let k = k_max.min(n / min_files.clamp(1, 64)).max(1);
    if sys::env(b"SWAN_STAMP_MODE") == b"threads" {
        prestamp_threads(repo, texts_dir, &todo, n, k, pre, report);
        return;
    }
    let exe = match sys::exe_path() {
        Some(e) => e,
        None => return,
    };
    let t0 = Instant::now();
    let mut children: Vec<Option<std::process::Child>> = Vec::new();
    for w in 0..k {
        let list = part_path(out, b"prestamp-", w, b".txt");
        let part = part_path(out, b"prestamp-", w, b".tsv");
        sys::delete_file(&part);
        let mut mine: Vec<u8> = Vec::new(); // every k-th file, so big and small files spread evenly
        let mut i: i64 = 0;
        for rel in todo.split(|&c| c == b'\n') {
            if rel.is_empty() {
                continue;
            }
            if i % k == w {
                mine.extend_from_slice(rel);
                mine.push(b'\n');
            }
            i += 1;
        }
        if !sys::write_file(&list, &mine) {
            children.push(None);
            continue;
        }
        let argv: [&[u8]; 6] = [&exe, b"stamp-worker", repo, &list, &part, texts_dir];
        children.push(sys::spawn_logged(&argv, repo, &part_path(out, b"prestamp-log-", w, b".txt")));
    }
    let codes: Vec<i32> = children.into_iter().map(|c| c.map_or(-1, sys::wait_code)).collect();
    let mut used = 0;
    for w in 0..k {
        let part = part_path(out, b"prestamp-", w, b".tsv");
        if codes[w as usize] == 0 {
            let mut t: Vec<u8> = Vec::new();
            if sys::read_file(&part, &mut t) {
                pre.extend_from_slice(&t);
                used += 1;
            }
        }
        sys::delete_file(&part);
        sys::delete_file(&part_path(out, b"prestamp-", w, b".txt"));
        sys::delete_file(&part_path(out, b"prestamp-log-", w, b".txt"));
    }
    report.extend_from_slice(format!("stamps: {} files on {} of {} workers in {} ms\n", n, used, k, ms_since(t0)).as_bytes());
}

// The same work on threads instead of processes: k workers take the files
// one by one and send each stamp line back.
fn prestamp_threads(repo: &[u8], texts_dir: &[u8], todo: &[u8], n: i64, k_want: i64, pre: &mut Vec<u8>, report: &mut Vec<u8>) {
    let t0 = Instant::now();
    let k = k_want.min(sys::hardware_threads()).max(1);
    let jobs: Vec<&[u8]> = todo.split(|&c| c == b'\n').filter(|rel| !rel.is_empty()).collect();
    let taken = AtomicUsize::new(0);
    let (send, done) = mpsc::channel::<Vec<u8>>();
    std::thread::scope(|s| {
        for _ in 0..k {
            let send = send.clone();
            let (jobs, taken) = (&jobs, &taken);
            s.spawn(move || loop {
                let j = taken.fetch_add(1, Ordering::Relaxed);
                if j >= jobs.len() {
                    break;
                }
                let mut line: Vec<u8> = Vec::new();
                stamp_line(repo, jobs[j], texts_dir, &mut line);
                if send.send(line).is_err() {
                    break;
                }
            });
        }
        drop(send);
        for line in done {
            pre.extend_from_slice(&line);
        }
    });
    report.extend_from_slice(format!("stamps: {} files on {} threads in {} ms\n", n, k, ms_since(t0)).as_bytes());
}

// One file's stamp line, as the map's `stamp` writes it to
// content-stamps.tsv: "path\tsize\tmtime\tstamp\traw\tc|b". Keeps the text
// of a file stamped by its code in texts_dir.
pub fn stamp_line(repo: &[u8], rel: &[u8], texts_dir: &[u8], line: &mut Vec<u8>) {
    let full = [repo, b"/", rel].concat();
    let size = sys::file_size(&full);
    let mt = sys::mtime_ns(&full);
    let mut text: Vec<u8> = Vec::new();
    sys::read_file(&full, &mut text);
    let raw = hash(&text);
    let mut st = raw;
    let mut by_code = false;
    let lang = cosmetic_lang(rel);
    if !lang.is_empty() {
        let (h, ok) = code_hash(lang, &text);
        if ok {
            st = h;
            by_code = true;
            let mut keep = [texts_dir, b"/t"].concat();
            push_int(&mut keep, raw as i64);
            keep.extend_from_slice(b".txt");
            if !sys::file_exists(&keep) {
                sys::write_file(&keep, &text);
            }
        }
    }
    line.extend_from_slice(rel);
    line.push(b'\t');
    push_int(line, size);
    line.push(b'\t');
    push_int(line, mt);
    line.push(b'\t');
    push_int(line, st as i64);
    line.push(b'\t');
    push_int(line, raw as i64);
    line.push(b'\t');
    line.push(if by_code { b'c' } else { b'b' });
    line.push(b'\n');
}

fn count_lines(s: &[u8]) -> i64 {
    s.iter().filter(|&&c| c == b'\n').count() as i64
}

// swan stamp-bench <repo> <out-dir>: the stamping a first map does, alone,
// timed, its lines written to <out-dir>/stamps.tsv. SWAN_STAMP_JOBS=1 stamps
// in this process, file after file; otherwise prestamp runs with
// SWAN_STAMP_MODE (processes, the default, or threads).
pub fn stamp_bench_main(repo_arg: &[u8], out_arg: &[u8]) -> bool {
    let repo = crate::abs_path(repo_arg);
    sys::make_dir(out_arg);
    let out = crate::abs_path(out_arg);
    let texts = [&out[..], b"/texts"].concat();
    sys::make_dir(&texts);
    let walk = Walk::default();
    let prev: Vec<u8> = Vec::new();
    let prev_at: HashMap<u64, usize> = HashMap::new();
    let mut pre: Vec<u8> = Vec::new();
    let mut report: Vec<u8> = Vec::new();
    let t0 = Instant::now();
    if stamp_jobs() == 1 {
        let mut n = 0;
        walk.each_file(&repo, |full, name| {
            if cosmetic_lang(name).is_empty() {
                return;
            }
            stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);
            n += 1;
        });
        report.extend_from_slice(format!("stamps: {} files in this process\n", n).as_bytes());
    } else {
        prestamp(&walk, &repo, &out, &texts, &prev, &prev_at, &mut pre, &mut report);
        // prestamp stamps nothing below SWAN_STAMP_MIN files, and leaves a
        // failed worker's files out: stamp them all here then, so stamps.tsv
        // always holds every eligible file.
        let mut n_all = 0;
        walk.each_file(&repo, |_, name| {
            if cosmetic_lang(name).is_empty() {
                return;
            }
            n_all += 1;
        });
        let got = count_lines(&pre);
        if got != n_all {
            report.extend_from_slice(format!("stamps: workers stamped {} of {} files; stamped them all in this process\n", got, n_all).as_bytes());
            pre.clear();
            walk.each_file(&repo, |full, name| {
                if cosmetic_lang(name).is_empty() {
                    return;
                }
                stamp_line(&repo, &full[repo.len() + 1..], &texts, &mut pre);
            });
        }
    }
    report.extend_from_slice(format!("stamp-bench: {} ms", ms_since(t0)).as_bytes());
    print(&report);
    sys::write_file(&[&out[..], b"/stamps.tsv"].concat(), &pre)
}

// swan stamp-worker <repo> <list> <out.tsv> <texts-dir>: a stamp line for
// each relative path in list.
pub fn stamp_worker_main(repo: &[u8], list: &[u8], out_path: &[u8], texts_dir: &[u8]) -> bool {
    let mut names: Vec<u8> = Vec::new();
    if !sys::read_file(list, &mut names) {
        return false;
    }
    let mut lines: Vec<u8> = Vec::new();
    for rel in names.split(|&c| c == b'\n') {
        if rel.is_empty() {
            continue;
        }
        stamp_line(repo, rel, texts_dir, &mut lines);
    }
    sys::write_file(out_path, &lines)
}
