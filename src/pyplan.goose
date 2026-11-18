// Planning scip-python's work: a Python repo is split into pieces (packages,
// or prefix groups of standalone scripts) that are indexed side by side and
// reused one by one when nothing they depend on changed.

import std;
import os;
import json;
import dictionary;
import sqlite;

// The first segments of the modules a Python file imports: F(segment), or
// F(".") for a relative import. Line by line, which is enough to tell a
// script that stands alone from one that needs the repo's own packages.
fn py_imports<F>(text: const u8[:]) {
    each_split(text, '\n') { raw =>
        let l = trim(raw);
        if starts_with(l, "from ") {
            let m = trim(l[5..]);
            if m.len > 0 && m[0] == '.' { F("."); }
            else {
                var e = 0;
                while e < m.len && (is_alnum(m[e]) || m[e] == '_') { e++; }
                if e > 0 { F(m[..e]); }
            }
        } else if starts_with(l, "import ") {
            each_split(l[7..], ',') { part =>
                let m = trim(part);
                var e = 0;
                while e < m.len && (is_alnum(m[e]) || m[e] == '_') { e++; }
                if e > 0 { F(m[..e]); }
            };
        }
    };
}

fn is_alnum(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') }

// What scip-python is told for a piece: a prefix piece ("dir/ab*": every
// path starting with dir/ab) loses its star; a folder or file piece is its
// own path.
fn piece_target(piece: const u8[:]) -> const u8[:] {
    return if piece.len > 0 && piece[piece.len - 1] == '*' { piece[..piece.len - 1] } else { piece };
}

// Splits everything directly in `dir` (its files, and its subfolders whole)
// into prefix pieces, appended to plan as "dir/prefix*". False, with plan
// untouched, when the folder's files do not stand alone (more than one in
// ten imports a name that is a folder or module of this repo, or imports
// relatively) or no clean split exists; the caller then keeps the folder
// whole.
fn plan_prefix_pieces(repo: const u8[:], dir: const u8[:], paths: const u8[:][:], sizes: const i64[:], limit: i64,
                      plan: u8[>..]&) -> bool {
    // This repo's own importable names: every folder on a .py file's path,
    // and every module's file name.
    var own = dictionary<u64, bool> {};
    for p in paths {
        var at = 0;
        while at < p.len {
            let sl = find(p[at..], "/");
            if sl < 0 {
                let stem = if ends_with(p[at..], ".py") { p[at..p.len - 3] } else { p[at..] };
                own.insert(hash(stem), true);
                break;
            }
            own.insert(hash(p[at..at + sl]), true);
            at = at + sl + 1;
        }
    }
    // The folder's children: a name, how many .py files and bytes it holds.
    var names: u8[>..] = [];
    var e_off: i64[>..] = [];
    var e_len: i64[>..] = [];
    var e_files: i64[>..] = [];
    var e_bytes: i64[>..] = [];
    var at_name = dictionary<u64, i64> {};
    var loose = 0;
    var needs_repo = 0;
    for p, i in paths {
        let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
        if inside {
            let rest = if dir.len == 0 { p } else { p[dir.len + 1..] };
            let slash = find(rest, "/");
            let name = if slash < 0 { rest } else { rest[..slash] };
            let known = at_name.get(hash(name));
            if known {
                let k: i64 = known;
                e_files[k] += 1;
                e_bytes[k] += sizes[i];
            } else {
                at_name.insert(hash(name), e_off.len);
                e_off.push(names.len);
                e_len.push(name.len);
                e_files.push(1);
                e_bytes.push(sizes[i]);
                names.append(name);
            }
            if slash < 0 {
                loose++;
                var text: u8[>..] = [];
                var full: u8[>..] = [];
                format(full, repo, "/", p);
                if read_file(full, text) {
                    var uses = false;
                    py_imports(text) { seg => if seg == "." || own.contains(hash(seg)) { uses = true; } };
                    if uses { needs_repo++; }
                }
            }
        }
    }
    guard loose > 0 && needs_repo * 10 <= loose else { return false; }

    // Groups of children sharing a name prefix: (one member, prefix length).
    // The biggest group over the limits is split by its next byte, until none
    // is over, or it cannot be (a name ends where the prefix does), or there
    // would be too many groups.
    var g_rep: i64[>..] = [];
    var g_len: i64[>..] = [];
    var g_done: i64[>..] = [];
    g_rep.push(0); g_len.push(0); g_done.push(0);
    fn name_of(k: i64) -> const u8[:] { names[e_off[k]..e_off[k] + e_len[k]] }
    fn in_group(k: i64, g: i64) -> bool { starts_with(name_of(k), name_of(g_rep[g])[..g_len[g]]) }
    // Lengthens a group's prefix to all that its members share.
    fn lengthen(g: i64) {
        var l = -1;
        let first = name_of(g_rep[g]);
        for k in e_off.len {
            if in_group(k, g) {
                let nm = name_of(k);
                var c = 0;
                while c < nm.len && c < first.len && nm[c] == first[c] { c++; }
                if l < 0 || c < l { l = c; }
            }
        }
        if l > g_len[g] { g_len[g] = l; }
    }
    lengthen(0);
    while true {
        var pick = -1;
        var pick_files = 0;
        for g in g_rep.len {
            if g_done[g] == 0 {
                var files = 0;
                var bytes = 0;
                for k in e_off.len { if in_group(k, g) { files += e_files[k]; bytes += e_bytes[k]; } }
                if (files > PY_PIECE_FILES || bytes > limit) && files > pick_files { pick = g; pick_files = files; }
            }
        }
        if pick < 0 { break; }
        // Its members by their next byte; a name that ends here stops the split.
        var next_seen: bool[256] = [false; 256];
        var kids = 0;
        var ends_here = false;
        for k in e_off.len {
            if in_group(k, pick) {
                let nm = name_of(k);
                if nm.len == g_len[pick] { ends_here = true; }
                else if !next_seen[nm[g_len[pick]]] { next_seen[nm[g_len[pick]]] = true; kids++; }
            }
        }
        if ends_here || kids < 2 || g_rep.len - 1 + kids > PY_PIECE_GROUPS { g_done[pick] = 1; continue; }
        let plen = g_len[pick];
        var first_kid = true;
        for b in 256 {
            if next_seen[b] {
                var rep = -1;
                for k in e_off.len {
                    if rep < 0 && in_group(k, pick) && name_of(k).len > plen && name_of(k)[plen] == (b as! u8) { rep = k; }
                }
                // The first child takes the parent's slot (after the scan above, which still reads it).
                if first_kid { first_kid = false; g_rep.push(rep); g_len.push(plen + 1); g_done.push(0); }
                else { g_rep.push(rep); g_len.push(plen + 1); g_done.push(0); }
            }
        }
        // Drop the parent: move the last group into its slot.
        let last = g_rep.len - 1;
        g_rep[pick] = g_rep[last]; g_len[pick] = g_len[last]; g_done[pick] = g_done[last];
        g_rep.pop(); g_len.pop(); g_done.pop();
        for g in g_rep.len { if g_done[g] == 0 { lengthen(g); } }
    }
    // One group left means nothing was split; "." and ".." cannot be told to
    // scip-python as a prefix (it would resolve them to the folder).
    guard g_rep.len > 1 else { return false; }
    for g in g_rep.len {
        let pre = name_of(g_rep[g])[..g_len[g]];
        if pre.len == 0 || pre == "." || pre == ".." { return false; }
    }
    // In name order, so the plan is the same every time.
    var order: i64[>..] = [];
    for g in g_rep.len { order.push(g); }
    sort(order) { a, b => bytes_before(name_of(g_rep[a])[..g_len[a]], name_of(g_rep[b])[..g_len[b]]) };
    for g in order {
        if dir.len > 0 { format(plan, dir, "/"); }
        format(plan, name_of(g_rep[g])[..g_len[g]], "*\n");
    }
    return true;
}

fn bytes_before(a: const u8[:], b: const u8[:]) -> bool {
    let n = min(a.len, b.len);
    for i in n { if a[i] != b[i] { return a[i] < b[i]; } }
    return a.len < b.len;
}

// Splits a repo's Python into pieces for parallel scip-python runs
// (--target-only), about k of similar size. A folder bigger than its share
// is split into its subfolders; a few .py files directly in it become
// pieces of their own; many of them stay together as the folder, unless
// they stand alone, when they are split by filename prefix
// (plan_prefix_pieces). Returns the pieces, relative to repo, one per line:
// a folder or file path, or "path/prefix*"; a single empty line means "the
// whole repo in one run".
fn plan_python(repo: const u8[:], k: i64) -> u8[>..] {
    var files: u8[>..] = [];        // "relative path\n" for every .py
    var sizes: i64[>..] = [];
    each_file(repo) { full, name =>
        if ends_with(name, ".py") {
            files.append(full[repo.len + 1..]);
            files.push('\n');
            sizes.push(max(swan_file_size(full), 1));
        }
    };
    var plan: u8[>..] = [];
    var total = 0;
    for z in sizes { total += z; }
    if k <= 1 || sizes.len < 2 * k { plan.push('\n'); return plan; }
    let paths = split(files[..files.len - 1], '\n');
    let limit = total / k;
    // A directory's size: every .py under it.
    fn size_under(dir: const u8[:]) -> i64 {
        var t = 0;
        for p, i in paths {
            if dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/') { t += sizes[i]; }
        }
        return t;
    }
    // Subdirectories of dir that hold .py files, and .py files directly in it.
    var queue: u8[>..] = [];
    queue.push('\n');               // the root, as an empty line
    var next = 0;
    while next < queue.len {
        let e = next + find(queue[next..], "\n");
        var dir: u8[>..] = [];
        dir.append(queue[next..e]);
        next = e + 1;
        if size_under(dir) <= limit && dir.len > 0 { plan.append(dir); plan.push('\n'); continue; }
        // scip-python takes one path per run, and every run analyses the
        // whole program again. A folder with more loose .py files than
        // there are pieces (a flat tests/ of hundreds of files) would become
        // one run per file: hundreds of whole-program runs. Index such a
        // folder in one run instead; at the root, index everything in one.
        var loose = 0;
        for p in paths {
            let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
            if inside && find(if dir.len == 0 { p } else { p[dir.len + 1..] }, "/") < 0 { loose++; }
        }
        if loose > k {
            // Unless its files stand alone. scip-python's --target-only keeps
            // every path that starts with the text it is given, so a folder
            // of scripts that import nothing of the repo's own (a test corpus
            // of standalone cases) is split by filename prefix, a few dozen
            // files to a run, on every core: each run then loads almost
            // nothing besides its own files. Files that import the repo's
            // packages stay together, since every run would load those again.
            if loose > PY_PIECE_FILES && plan_prefix_pieces(repo, dir, paths, sizes, limit, plan) { continue; }
            if dir.len == 0 { plan.clear(); plan.push('\n'); return plan; }
            plan.append(dir); plan.push('\n');
            continue;
        }
        var subs = dictionary<const u8[:], bool> {};
        for p in paths {
            let inside = dir.len == 0 || (starts_with(p, dir) && p.len > dir.len && p[dir.len] == '/');
            if inside {
                let rest = if dir.len == 0 { p } else { p[dir.len + 1..] };
                let slash = find(rest, "/");
                if slash < 0 {
                    plan.append(p);
                    plan.push('\n');
                } else {
                    let sub = p[..(if dir.len == 0 { 0 } else { dir.len + 1 }) + slash];
                    if !subs.contains(sub) {
                        subs.insert(sub, true);
                        queue.append(sub);
                        queue.push('\n');
                    }
                }
            }
        }
    }
    return plan;
}
