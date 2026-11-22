// Planning scip-python's work: a Python repo is split into pieces (packages,
// or prefix groups of standalone scripts) that are indexed side by side and
// reused one by one when nothing they depend on changed. Carried over from
// src/pyplan.goose; piece_target, which only the map uses, comes with the
// map at stage 4.

use std::collections::{HashMap, HashSet};

use crate::sys;
use crate::util::{ends_with, find, hash, split, starts_with, trim};
use crate::walk::Walk;

// From src/pipeline.goose: a prefix piece holds at most this many files, and
// a folder is split into at most this many prefix pieces.
const PY_PIECE_FILES: i64 = 64;
const PY_PIECE_GROUPS: usize = 40;

fn is_alnum(c: u8) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_uppercase() || c.is_ascii_digit()
}

// The first word of `m`: letters, digits and '_'.
// What scip-python is told for a piece: a prefix piece ("dir/ab*": every
// path starting with dir/ab) loses its star; a folder or file piece is its
// own path.
pub fn piece_target(piece: &[u8]) -> &[u8] {
    if !piece.is_empty() && piece[piece.len() - 1] == b'*' {
        &piece[..piece.len() - 1]
    } else {
        piece
    }
}

fn first_word(m: &[u8]) -> &[u8] {
    let mut e = 0;
    while e < m.len() && (is_alnum(m[e]) || m[e] == b'_') {
        e += 1;
    }
    &m[..e]
}

// The first segments of the modules a Python file imports: f(segment), or
// f(".") for a relative import. Line by line, which is enough to tell a
// script that stands alone from one that needs the repo's own packages.
fn py_imports(text: &[u8], mut f: impl FnMut(&[u8])) {
    for raw in text.split(|&c| c == b'\n') {
        let l = trim(raw);
        if starts_with(l, b"from ") {
            let m = trim(&l[5..]);
            if !m.is_empty() && m[0] == b'.' {
                f(b".");
            } else {
                let w = first_word(m);
                if !w.is_empty() {
                    f(w);
                }
            }
        } else if starts_with(l, b"import ") {
            for part in l[7..].split(|&c| c == b',') {
                let w = first_word(trim(part));
                if !w.is_empty() {
                    f(w);
                }
            }
        }
    }
}

// Whether p is inside folder dir ("" is the repo).
fn inside(p: &[u8], dir: &[u8]) -> bool {
    dir.is_empty() || (starts_with(p, dir) && p.len() > dir.len() && p[dir.len()] == b'/')
}

// Splits everything directly in `dir` (its files, and its subfolders whole)
// into prefix pieces, appended to plan as "dir/prefix*". False, with plan
// untouched, when the folder's files do not stand alone (more than one in
// ten imports a name that is a folder or module of this repo, or imports
// relatively) or no clean split exists; the caller then keeps the folder
// whole.
fn plan_prefix_pieces(repo: &[u8], dir: &[u8], paths: &[&[u8]], sizes: &[i64], limit: i64, plan: &mut Vec<u8>) -> bool {
    // This repo's own importable names: every folder on a .py file's path,
    // and every module's file name. Kept by hash, as the Goose program
    // keeps them (a collision merges two names in both).
    let mut own: HashSet<u64> = HashSet::new();
    for p in paths {
        let mut at = 0;
        while at < p.len() {
            let sl = find(&p[at..], b"/");
            if sl < 0 {
                let stem = if ends_with(&p[at..], b".py") { &p[at..p.len() - 3] } else { &p[at..] };
                own.insert(hash(stem));
                break;
            }
            let sl = sl as usize;
            own.insert(hash(&p[at..at + sl]));
            at = at + sl + 1;
        }
    }
    // The folder's children: a name, how many .py files and bytes it holds.
    let mut names: Vec<&[u8]> = Vec::new();
    let mut e_files: Vec<i64> = Vec::new();
    let mut e_bytes: Vec<i64> = Vec::new();
    let mut at_name: HashMap<u64, usize> = HashMap::new();
    let mut loose = 0;
    let mut needs_repo = 0;
    for (i, p) in paths.iter().enumerate() {
        if !inside(p, dir) {
            continue;
        }
        let rest = if dir.is_empty() { *p } else { &p[dir.len() + 1..] };
        let slash = find(rest, b"/");
        let name = if slash < 0 { rest } else { &rest[..slash as usize] };
        match at_name.get(&hash(name)) {
            Some(&k) => {
                e_files[k] += 1;
                e_bytes[k] += sizes[i];
            }
            None => {
                at_name.insert(hash(name), names.len());
                names.push(name);
                e_files.push(1);
                e_bytes.push(sizes[i]);
            }
        }
        if slash < 0 {
            loose += 1;
            let mut text: Vec<u8> = Vec::new();
            if sys::read_file(&[repo, b"/", p].concat(), &mut text) {
                let mut uses = false;
                py_imports(&text, |seg| {
                    if seg == b"." || own.contains(&hash(seg)) {
                        uses = true;
                    }
                });
                if uses {
                    needs_repo += 1;
                }
            }
        }
    }
    if !(loose > 0 && needs_repo * 10 <= loose) {
        return false;
    }

    // Groups of children sharing a name prefix: (one member, prefix length).
    // The biggest group over the limits is split by its next byte, until none
    // is over, or it cannot be (a name ends where the prefix does), or there
    // would be too many groups.
    let n = names.len();
    let mut g_rep: Vec<usize> = vec![0];
    let mut g_len: Vec<usize> = vec![0];
    let mut g_done: Vec<bool> = vec![false];
    let in_group = |k: usize, rep: usize, len: usize| starts_with(names[k], &names[rep][..len]);
    // Lengthens a group's prefix to all that its members share.
    let lengthen = |g: usize, g_rep: &[usize], g_len: &mut [usize]| {
        let mut l: i64 = -1;
        let first = names[g_rep[g]];
        for k in 0..n {
            if in_group(k, g_rep[g], g_len[g]) {
                let nm = names[k];
                let mut c = 0;
                while c < nm.len() && c < first.len() && nm[c] == first[c] {
                    c += 1;
                }
                if l < 0 || (c as i64) < l {
                    l = c as i64;
                }
            }
        }
        if l > g_len[g] as i64 {
            g_len[g] = l as usize;
        }
    };
    lengthen(0, &g_rep, &mut g_len);
    loop {
        let mut pick: i64 = -1;
        let mut pick_files = 0;
        for g in 0..g_rep.len() {
            if !g_done[g] {
                let mut files = 0;
                let mut bytes = 0;
                for k in 0..n {
                    if in_group(k, g_rep[g], g_len[g]) {
                        files += e_files[k];
                        bytes += e_bytes[k];
                    }
                }
                if (files > PY_PIECE_FILES || bytes > limit) && files > pick_files {
                    pick = g as i64;
                    pick_files = files;
                }
            }
        }
        if pick < 0 {
            break;
        }
        let pick = pick as usize;
        // Its members by their next byte; a name that ends here stops the split.
        let plen = g_len[pick];
        let mut next_seen = [false; 256];
        let mut kids = 0;
        let mut ends_here = false;
        for k in 0..n {
            if in_group(k, g_rep[pick], plen) {
                let nm = names[k];
                if nm.len() == plen {
                    ends_here = true;
                } else if !next_seen[nm[plen] as usize] {
                    next_seen[nm[plen] as usize] = true;
                    kids += 1;
                }
            }
        }
        if ends_here || kids < 2 || g_rep.len() - 1 + kids > PY_PIECE_GROUPS {
            g_done[pick] = true;
            continue;
        }
        for (b, &seen) in next_seen.iter().enumerate() {
            if seen {
                let mut rep: i64 = -1;
                for k in 0..n {
                    if rep < 0 && in_group(k, g_rep[pick], plen) && names[k].len() > plen && names[k][plen] == b as u8 {
                        rep = k as i64;
                    }
                }
                g_rep.push(rep as usize);
                g_len.push(plen + 1);
                g_done.push(false);
            }
        }
        // Drop the parent: move the last group into its slot.
        let last = g_rep.len() - 1;
        g_rep[pick] = g_rep[last];
        g_len[pick] = g_len[last];
        g_done[pick] = g_done[last];
        g_rep.pop();
        g_len.pop();
        g_done.pop();
        for g in 0..g_rep.len() {
            if !g_done[g] {
                lengthen(g, &g_rep, &mut g_len);
            }
        }
    }
    // One group left means nothing was split; "." and ".." cannot be told to
    // scip-python as a prefix (it would resolve them to the folder).
    if g_rep.len() <= 1 {
        return false;
    }
    let prefix = |g: usize| &names[g_rep[g]][..g_len[g]];
    for g in 0..g_rep.len() {
        let pre = prefix(g);
        if pre.is_empty() || pre == b"." || pre == b".." {
            return false;
        }
    }
    // In name order, so the plan is the same every time. The prefixes all
    // differ, so this order is the one the Goose program's sort gives.
    let mut order: Vec<usize> = (0..g_rep.len()).collect();
    order.sort_by(|&a, &b| prefix(a).cmp(prefix(b)));
    for g in order {
        if !dir.is_empty() {
            plan.extend_from_slice(dir);
            plan.push(b'/');
        }
        plan.extend_from_slice(prefix(g));
        plan.extend_from_slice(b"*\n");
    }
    true
}

// Splits a repo's Python into pieces for parallel scip-python runs
// (--target-only), about k of similar size. A folder bigger than its share
// is split into its subfolders; a few .py files directly in it become
// pieces of their own; many of them stay together as the folder, unless
// they stand alone, when they are split by filename prefix
// (plan_prefix_pieces). Returns the pieces, relative to repo, one per line:
// a folder or file path, or "path/prefix*"; a single empty line means "the
// whole repo in one run".
pub fn plan_python(walk: &Walk, repo: &[u8], k: i64) -> Vec<u8> {
    let mut files: Vec<u8> = Vec::new(); // "relative path\n" for every .py
    let mut sizes: Vec<i64> = Vec::new();
    walk.each_file(repo, |full, name| {
        if ends_with(name, b".py") {
            files.extend_from_slice(&full[repo.len() + 1..]);
            files.push(b'\n');
            sizes.push(sys::file_size(full).max(1));
        }
    });
    let mut plan: Vec<u8> = Vec::new();
    let total: i64 = sizes.iter().sum();
    if k <= 1 || (sizes.len() as i64) < 2 * k {
        plan.push(b'\n');
        return plan;
    }
    let paths = split(&files[..files.len() - 1], b'\n');
    let limit = total / k;
    // A directory's size: every .py under it.
    let size_under = |dir: &[u8]| -> i64 {
        let mut t = 0;
        for (i, p) in paths.iter().enumerate() {
            if inside(p, dir) {
                t += sizes[i];
            }
        }
        t
    };
    // Subdirectories of dir that hold .py files, and .py files directly in it.
    let mut queue: Vec<u8> = vec![b'\n']; // the root, as an empty line
    let mut next = 0;
    while next < queue.len() {
        let e = next + find(&queue[next..], b"\n") as usize;
        let dir: Vec<u8> = queue[next..e].to_vec();
        next = e + 1;
        if size_under(&dir) <= limit && !dir.is_empty() {
            plan.extend_from_slice(&dir);
            plan.push(b'\n');
            continue;
        }
        // scip-python takes one path per run, and every run analyses the
        // whole program again. A folder with more loose .py files than
        // there are pieces (a flat tests/ of hundreds of files) would become
        // one run per file: hundreds of whole-program runs. Index such a
        // folder in one run instead; at the root, index everything in one.
        let mut loose = 0;
        for p in &paths {
            if inside(p, &dir) && find(if dir.is_empty() { p } else { &p[dir.len() + 1..] }, b"/") < 0 {
                loose += 1;
            }
        }
        if loose > k {
            // Unless its files stand alone. scip-python's --target-only keeps
            // every path that starts with the text it is given, so a folder
            // of scripts that import nothing of the repo's own (a test corpus
            // of standalone cases) is split by filename prefix, a few dozen
            // files to a run, on every core: each run then loads almost
            // nothing besides its own files. Files that import the repo's
            // packages stay together, since every run would load those again.
            if loose > PY_PIECE_FILES && plan_prefix_pieces(repo, &dir, &paths, &sizes, limit, &mut plan) {
                continue;
            }
            if dir.is_empty() {
                plan.clear();
                plan.push(b'\n');
                return plan;
            }
            plan.extend_from_slice(&dir);
            plan.push(b'\n');
            continue;
        }
        let mut subs: HashSet<&[u8]> = HashSet::new();
        for p in &paths {
            if !inside(p, &dir) {
                continue;
            }
            let rest = if dir.is_empty() { *p } else { &p[dir.len() + 1..] };
            let slash = find(rest, b"/");
            if slash < 0 {
                plan.extend_from_slice(p);
                plan.push(b'\n');
            } else {
                let sub = &p[..(if dir.is_empty() { 0 } else { dir.len() + 1 }) + slash as usize];
                if subs.insert(sub) {
                    queue.extend_from_slice(sub);
                    queue.push(b'\n');
                }
            }
        }
    }
    plan
}
