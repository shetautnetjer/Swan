// The TypeScript projects of a repo.
//
// A repo can hold more than one tsconfig: a package of a monorepo with its
// own (its own `jsx`, `paths`, libraries), or a tsconfig.json that only
// references tsconfig.app.json and tsconfig.node.json. Swan indexed every
// file under the root tsconfig alone. On Egonex-AI/Understand-Anything
// (2026-11-17, found by comparing with WebStorm) the root one has no `jsx`
// and the dashboard package's own sets it: TypeScript does not follow an
// import that resolves to a .tsx file when `jsx` is unset, so a .tsx file
// in another chunk was not loaded, and the import and every use of what it
// brought in was lost (621 rows, 136 of App.tsx's 450). A package with a
// tsconfig of its own that the root one did not include had no rows at all.
//
// Each file is now indexed under the config that owns it, chosen the way an
// editor's language service chooses: the nearest config above the file that
// lists it. A config is a project when it is a tsconfig.json somewhere in
// the repo or one that such a config (or the root's) references. What a
// config lists is tsc's own answer, `tsc -p <config> --showConfig`, asked
// sealed like every other step of the map.
//
// Carried over from src/tsproj.goose.

use std::collections::{HashMap, HashSet};

use crate::json;
use crate::seal::sealed_run;
use crate::sys;
use crate::util::{ends_with, find, hash, parse_int, push_int, starts_with, trim};

// How many configs besides the root's one map asks tsc about. Each is a tsc
// run (a fifth of a second on a small package); the answers are kept until
// a file comes or goes or a tsconfig changes.
const TS_PROJECT_LIMIT: i64 = 64;

// The folder a file is in.
fn ts_folder(path: &[u8]) -> &[u8] {
    let mut cut = path.len();
    while cut > 0 && path[cut - 1] != b'/' {
        cut -= 1;
    }
    &path[..cut.saturating_sub(1)]
}

// How near a config is to a file: 0 when its folder is not above the file,
// else more the deeper the folder.
fn ts_nearness(config: &[u8], file: &[u8]) -> i64 {
    let dir = ts_folder(config);
    if !(!dir.is_empty() && file.len() > dir.len() && starts_with(file, dir) && file[dir.len()] == b'/') {
        return 0;
    }
    dir.len() as i64
}

// tsc's account of a config (what `tsc -p <config> --showConfig` printed):
// its root files, absolute and real, one per line, and the configs it
// references. False when the output is not that.
fn ts_show_parse(show: &[u8], cfg_dir: &[u8], files: &mut Vec<u8>, refs: &mut Vec<u8>) -> bool {
    let Some(doc) = json::parse(show) else {
        return false;
    };
    let root = doc.root();
    if root.is_none() {
        return false;
    }
    let resolved = |rel: &[u8]| -> Vec<u8> {
        let p = if rel[0] == b'/' {
            rel.to_vec()
        } else if starts_with(rel, b"./") {
            [cfg_dir, b"/", &rel[2..]].concat()
        } else {
            [cfg_dir, b"/", rel].concat()
        };
        sys::realpath(&p).unwrap_or(p)
    };
    if let Some(list) = doc.member(root, b"files") {
        for part in doc.each(list) {
            if let Some(s) = doc.as_string(Some(part)) {
                if !s.is_empty() {
                    files.extend_from_slice(&resolved(s));
                    files.push(b'\n');
                }
            }
        }
    }
    if let Some(rl) = doc.member(root, b"references") {
        for part in doc.each(rl) {
            if let Some(s) = doc.as_string(doc.member(Some(part), b"path")) {
                if !s.is_empty() {
                    let mut p = resolved(s);
                    if sys::is_dir(&p) {
                        p.extend_from_slice(b"/tsconfig.json");
                    }
                    if sys::file_exists(&p) {
                        refs.extend_from_slice(&p);
                        refs.push(b'\n');
                    }
                }
            }
        }
    }
    true
}

// One more config to ask, unless it is the root's or is waiting already.
fn enqueue(queue: &mut Vec<Vec<u8>>, base: &[u8], c: &[u8]) {
    if !c.is_empty() && c != base && !queue.iter().any(|q| q == c) {
        queue.push(c.to_vec());
    }
}

// A line "index \t file" of the files the configs list.
fn listed_line(line: &[u8]) -> Option<(usize, &[u8])> {
    let tab = find(line, b"\t");
    if tab <= 0 {
        return None;
    }
    let i = parse_int(&line[..tab as usize]).unwrap_or(0);
    Some((i as usize, &line[tab as usize + 1..]))
}

// The files that a config other than `base` owns, as lines "config \t file"
// with each config's lines together. `nested` is every tsconfig.json below
// the repo's root; the configs they and `base` reference are followed.
// `base_files` is what `base` lists: a file it lists stays with it unless a
// config nearer the file lists it too. `note` gets a line for the report.
#[allow(clippy::too_many_arguments)]
pub fn ts_other_projects(repo: &[u8], out: &[u8], trusted: bool, tsc: &[u8], env: &[&[u8]], base: &[u8], base_files: &[u8], nested: &[u8], note: &mut Vec<u8>) -> Vec<u8> {
    let mut queue: Vec<Vec<u8>> = Vec::new(); // configs to ask; only grows
    let ask = |config: &[u8], files: &mut Vec<u8>, refs: &mut Vec<u8>| -> bool {
        let mut o: Vec<u8> = Vec::new();
        let mut e: Vec<u8> = Vec::new();
        if sealed_run(&[tsc, b"-p", config, b"--showConfig"], repo, out, trusted, env, 120000, &mut o, &mut e) != 0 {
            return false;
        }
        ts_show_parse(&o, ts_folder(config), files, refs)
    };
    let base_in_repo = starts_with(base, &[repo, b"/"].concat());
    if base_in_repo {
        let mut bf: Vec<u8> = Vec::new();
        let mut br: Vec<u8> = Vec::new();
        if ask(base, &mut bf, &mut br) {
            for r in br.split(|&c| c == b'\n') {
                enqueue(&mut queue, base, r);
            }
        }
    }
    for c in nested.split(|&c| c == b'\n') {
        enqueue(&mut queue, base, c);
    }

    let mut cfgs: Vec<Vec<u8>> = Vec::new(); // those that answered
    let mut listed: Vec<u8> = Vec::new(); // "index \t file" for every file one of them lists
    let mut n: i64 = 0;
    let mut unread: i64 = 0;
    let mut over: i64 = 0;
    let mut next = 0;
    while next < queue.len() {
        let config = queue[next].clone();
        next += 1;
        if n >= TS_PROJECT_LIMIT {
            over += 1;
            continue;
        }
        let mut files: Vec<u8> = Vec::new();
        let mut refs: Vec<u8> = Vec::new();
        if !ask(&config, &mut files, &mut refs) {
            unread += 1;
            continue;
        }
        for r in refs.split(|&c| c == b'\n') {
            enqueue(&mut queue, base, r);
        }
        cfgs.push(config);
        for f in files.split(|&c| c == b'\n') {
            if !f.is_empty() {
                push_int(&mut listed, n);
                listed.push(b'\t');
                listed.extend_from_slice(f);
                listed.push(b'\n');
            }
        }
        n += 1;
    }
    let mut others: Vec<u8> = Vec::new();
    if n == 0 {
        if unread > 0 {
            note.extend_from_slice(b"typescript: ");
            push_int(note, unread);
            note.extend_from_slice(b" more tsconfig files could not be read by tsc; their files stay with the root's\n");
        }
        return others;
    }
    // Who has each file now: -1 the root's config, else an index into cfgs.
    let mut owner: HashMap<u64, i64> = HashMap::new();
    for raw in base_files.split(|&c| c == b'\n') {
        let f = trim(raw);
        if !f.is_empty() {
            let real = sys::realpath(f).unwrap_or_else(|| f.to_vec());
            owner.insert(hash(&real), -1);
        }
    }
    for line in listed.split(|&c| c == b'\n') {
        let Some((i, f)) = listed_line(line) else {
            continue;
        };
        match owner.get(&hash(f)).copied() {
            None => {
                owner.insert(hash(f), i as i64);
            }
            Some(old) => {
                let near_old = if old < 0 {
                    if base_in_repo {
                        ts_nearness(base, f)
                    } else {
                        0
                    }
                } else {
                    ts_nearness(&cfgs[old as usize], f)
                };
                let near_new = ts_nearness(&cfgs[i], f);
                // In one folder its tsconfig.json comes before the configs that one references.
                let old_main = if old < 0 { base_in_repo } else { ends_with(&cfgs[old as usize], b"/tsconfig.json") };
                if near_new > near_old || (near_new == near_old && !old_main && ends_with(&cfgs[i], b"/tsconfig.json")) {
                    owner.insert(hash(f), i as i64);
                }
            }
        }
    }
    let mut given: HashSet<u64> = HashSet::new();
    let mut owning: i64 = 0;
    let mut last: i64 = -1;
    for line in listed.split(|&c| c == b'\n') {
        let Some((i, f)) = listed_line(line) else {
            continue;
        };
        let Some(&o) = owner.get(&hash(f)) else {
            continue;
        };
        if o == i as i64 && !given.contains(&hash(f)) {
            given.insert(hash(f));
            others.extend_from_slice(&cfgs[i]);
            others.push(b'\t');
            others.extend_from_slice(f);
            others.push(b'\n');
            if i as i64 != last {
                owning += 1;
                last = i as i64;
            }
        }
    }
    note.extend_from_slice(b"typescript: ");
    push_int(note, owning);
    note.extend_from_slice(b" more tsconfig projects own files, each indexed under its own config");
    if unread > 0 {
        note.extend_from_slice(b"; ");
        push_int(note, unread);
        note.extend_from_slice(b" could not be read by tsc");
    }
    if over > 0 {
        note.extend_from_slice(b"; ");
        push_int(note, over);
        note.extend_from_slice(b" past the limit of ");
        push_int(note, TS_PROJECT_LIMIT);
        note.extend_from_slice(b" not asked");
    }
    note.push(b'\n');
    others
}
