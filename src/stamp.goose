// Content stamps: one line per source file (size, time, hash, code spans),
// computed in worker processes or threads, one per core, and kept in
// content-stamps.tsv so unchanged files are not read again.

import std;
import os;
import json;
import dictionary;
import sqlite;

// Whether content-stamps.tsv already holds this file's stamp (same size and
// mtime), so map_main's `stamp` would not read it.
fn stamp_known(prev: const u8[:], prev_at: dictionary<u64, i64>&, rel: const u8[:], full: const u8[:]) -> bool {
    let line = line_of_path(prev, prev_at, rel);
    guard line.len > 0 else { return false; }
    let f = split(line, '\t');
    return f.len == 6 && f[1] == str(swan_file_size(full)) && f[2] == str(swan_mtime_ns(full));
}

// How many stamp workers to start: $SWAN_STAMP_JOBS, else every core, at
// most 32. 1 stamps in this process, as before.
fn stamp_jobs() -> i64 {
    var v: u8[>..] = [];
    if env("SWAN_STAMP_JOBS", v) {
        let n, ok = parse_int(v);
        if ok && n > 0 { return n; }
    }
    return max(1, min(32, swan_cpu_count() as i64));
}

// A first map parses every TypeScript, JavaScript and Python file to stamp
// its code (src/change.goose), one after another: 6.6 s on rea. This stamps
// the files content-stamps.tsv does not already hold in `swan stamp-worker`
// processes, one per core, and leaves their lines in `pre`. The workers run
// the same code (stamp_file), so a stamp is the same whichever process made
// it; a worker that fails leaves its files to be stamped here.
fn prestamp(repo: const u8[:], out: const u8[:], texts_dir: const u8[:], prev: const u8[:], prev_at: dictionary<u64, i64>&,
            pre: u8[>..]&, report: u8[>..]&) {
    let k_max = stamp_jobs();
    guard k_max > 1 else { return; }
    var todo: u8[>..] = [];        // relative paths, one per line
    var n = 0;
    each_file(repo) { full, name =>
        guard cosmetic_lang(name).len > 0;
        let rel = full[repo.len + 1..];
        guard !stamp_known(prev, prev_at, rel, full);
        format(todo, rel, "\n");
        n++;
    };
    // Below a few hundred files starting processes costs more than it saves.
    var min_files: i64 = 256;
    var mv: u8[>..] = [];
    if env("SWAN_STAMP_MIN", mv) {
        let m, ok = parse_int(mv);
        if ok && m > 0 { min_files = m; }
    }
    guard n >= min_files else { return; }
    let k = max(1, min(k_max, n / max(1, min(64, min_files))));
    var mode: u8[>..] = [];
    if env("SWAN_STAMP_MODE", mode) && mode == "threads" {
        prestamp_threads(repo, texts_dir, todo, n, k, pre, report);
        return;
    }
    var exe: u8[>..] = [];
    guard swan_exe_path(exe) else { return; }
    let t0 = clock();
    var started = 0;
    var pids: i64[>..] = [];
    for w in k {
        let list = str(out, "/prestamp-", w, ".txt");
        delete_file(str(out, "/prestamp-", w, ".tsv"));
        var mine: u8[>..] = [];    // every k-th file, so big and small files spread evenly
        var i = 0;
        each_split(todo, '\n') { rel =>
            guard rel.len > 0;
            if i % k == w { format(mine, rel, "\n"); }
            i++;
        };
        guard write_file(list, mine) else { pids.push(0); continue; }
        var a: u8[>..] = [];
        arg(a, exe);
        arg(a, "stamp-worker");
        arg(a, repo);
        arg(a, list);
        arg(a, str(out, "/prestamp-", w, ".tsv"));
        arg(a, texts_dir);
        let pid = swan_spawn(a[..], repo, "", str(out, "/prestamp-log-", w, ".txt"));
        pids.push(pid);
        if pid > 0 { started++; }
    }
    var codes: i32[>..] = [];
    for w in k { codes.push(-1); }
    while started > 0 {
        var code: i32 = 0;
        let pid = swan_wait_any(code);
        guard pid > 0 else { started = 0; continue; }
        for p, w in pids { if p == pid { codes[w] = code; started--; } }
    }
    var used = 0;
    for w in k {
        let part = str(out, "/prestamp-", w, ".tsv");
        if codes[w] == 0 {
            var t: u8[>..] = [];
            if read_file(part, t) { pre.append(t); used++; }
        }
        delete_file(part);
        delete_file(str(out, "/prestamp-", w, ".txt"));
        delete_file(str(out, "/prestamp-log-", w, ".txt"));
    }
    format(report, "stamps: ", n, " files on ", used, " of ", k, " workers in ", ((clock() - t0) * 1000.0) as i64, " ms\n");
}

// The same work on Goose threads instead of processes: the files go into a
// queue, k workers take them and send each stamp line back. Goose threads
// share no memory, so a job and a line are copied through the queue.
struct StampJob { spec: u8[] }      // repo \x01 texts dir \x01 relative path; empty: stop
struct StampDone { line: u8[] }

thread_fn stamp_thread() {
    loop {
        let job = qget<StampJob>();
        guard job.spec.len > 0 else { break; }
        let f = split(job.spec, 1);
        var line: u8[>..] = [];
        stamp_line(f[0], f[2], f[1], line);
        qput(StampDone { line: copy(line) });
    }
}

fn prestamp_threads(repo: const u8[:], texts_dir: const u8[:], todo: const u8[:], n: i64, k_want: i64,
                    pre: u8[>..]&, report: u8[>..]&) {
    let t0 = clock();
    let k = max(1, min(k_want, hardware_threads()));
    var queued = 0;
    each_split(todo, '\n') { rel =>
        guard rel.len > 0;
        var spec: u8[>..] = [];
        spec.append(repo); spec.push(1); spec.append(texts_dir); spec.push(1); spec.append(rel);
        qput(StampJob { spec: copy(spec) });
        queued++;
    };
    for i in k { qput(StampJob { spec: [] }); }
    var ids: i64[>..] = [];
    for i in k { ids.push(thread_spawn(stamp_thread)); }
    for d in queued {
        let r = qget<StampDone>();
        pre.append(r.line);
    }
    for id in ids { thread_wait(id); }
    format(report, "stamps: ", n, " files on ", k, " threads in ", ((clock() - t0) * 1000.0) as i64, " ms\n");
}

// One file's stamp line, as map_main's `stamp` writes it to
// content-stamps.tsv: "path\tsize\tmtime\tstamp\traw\tc|b". Keeps the text
// of a file stamped by its code in texts_dir.
fn stamp_line(repo: const u8[:], rel: const u8[:], texts_dir: const u8[:], line: u8[>..]&) {
    let full = str(repo, "/", rel);
    let size = swan_file_size(full);
    let mt = swan_mtime_ns(full);
    var text: u8[>..] = [];
    read_file(full, text);
    let raw = hash(text[..]);
    var st = raw;
    var by_code = false;
    let lang = cosmetic_lang(rel);
    if lang.len > 0 {
        let h, ok = code_hash(lang, text[..]);
        if ok {
            st = h;
            by_code = true;
            let keep = str(texts_dir, "/t", raw as! i64, ".txt");
            if !file_exists(keep) { write_file(keep, text[..]); }
        }
    }
    format(line, rel, "\t", size, "\t", mt, "\t", st as! i64, "\t", raw as! i64, "\t", if by_code { "c" } else { "b" }, "\n");
}

// swan stamp-bench <repo> <out-dir>: the stamping a first map does, alone,
// timed, its lines written to <out-dir>/stamps.tsv. SWAN_STAMP_JOBS=1 stamps
// in this process, file after file; otherwise prestamp runs with
// SWAN_STAMP_MODE (processes, the default, or threads).
fn stamp_bench_main(repo_arg: const u8[:], out_arg: const u8[:]) -> bool {
    let repo = abs_path(repo_arg);
    make_dir(out_arg);
    let out = abs_path(out_arg);
    let texts = str(out, "/texts");
    make_dir(texts);
    var prev: u8[>..] = [];
    var prev_at = dictionary<u64, i64> {};
    var pre: u8[>..] = [];
    var report: u8[>..] = [];
    let t0 = clock();
    if stamp_jobs() == 1 {
        var n = 0;
        each_file(repo) { full, name =>
            guard cosmetic_lang(name).len > 0;
            stamp_line(repo, full[repo.len + 1..], texts, pre);
            n++;
        };
        format(report, "stamps: ", n, " files in this process\n");
    } else {
        prestamp(repo, out, texts, prev, prev_at, pre, report);
        // prestamp stamps nothing below SWAN_STAMP_MIN files, and leaves a
        // failed worker's files out: stamp them all here then, so stamps.tsv
        // always holds every eligible file.
        var n_all = 0;
        each_file(repo) { full, name =>
            guard cosmetic_lang(name).len > 0;
            n_all++;
        };
        let got = count_lines(pre);
        if got != n_all {
            format(report, "stamps: workers stamped ", got, " of ", n_all, " files; stamped them all in this process\n");
            pre.clear();
            each_file(repo) { full, name =>
                guard cosmetic_lang(name).len > 0;
                stamp_line(repo, full[repo.len + 1..], texts, pre);
            };
        }
    }
    format(report, "stamp-bench: ", ((clock() - t0) * 1000.0) as i64, " ms");
    print(report);
    return write_file(str(out, "/stamps.tsv"), pre);
}

// swan stamp-worker <repo> <list> <out.tsv> <texts-dir>: a stamp line for
// each relative path in list.
fn stamp_worker_main(repo: const u8[:], list: const u8[:], out_path: const u8[:], texts_dir: const u8[:]) -> bool {
    var names: u8[>..] = [];
    guard read_file(list, names) else { return false; }
    var lines: u8[>..] = [];
    each_split(names, '\n') { rel =>
        guard rel.len > 0;
        stamp_line(repo, rel, texts_dir, lines);
    };
    return write_file(out_path, lines);
}
