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

import std;
import os;
import json;
import dictionary;

// How many configs besides the root's one map asks tsc about. Each is a tsc
// run (a fifth of a second on a small package); the answers are kept until
// a file comes or goes or a tsconfig changes.
let TS_PROJECT_LIMIT = 64;

// The folder a file is in.
fn ts_folder(path: const u8[:]) -> const u8[:] {
    var cut = path.len;
    while cut > 0 && path[cut - 1] != '/' { cut--; }
    return path[..max(cut - 1, 0)];
}

// How near a config is to a file: 0 when its folder is not above the file,
// else more the deeper the folder.
fn ts_nearness(config: const u8[:], file: const u8[:]) -> i64 {
    let dir = ts_folder(config);
    guard dir.len > 0 && file.len > dir.len && starts_with(file, dir) && file[dir.len] == '/' else { return 0; }
    return dir.len;
}

// tsc's account of a config (what `tsc -p <config> --showConfig` printed):
// its root files, absolute and real, one per line, and the configs it
// references. False when the output is not that.
fn ts_show_parse(show: const u8[:], cfg_dir: const u8[:], files: u8[>..]&, refs: u8[>..]&) -> bool {
    var text: u8[>..] = [];
    text.append(show);
    var doc: json::Node[>..] = [];
    var dec: u8[>..] = [];
    let root, err = json::parse(text, doc, dec);
    guard root else { return false; }
    fn resolved(rel: const u8[:], into: u8[>..]&) {
        var p: u8[>..] = [];
        if rel[0] == '/' { p.append(rel); }
        else if starts_with(rel, "./") { format(p, cfg_dir, "/", rel[2..]); }
        else { format(p, cfg_dir, "/", rel); }
        if !swan_realpath(p, into) { into.append(p); }
    }
    let list = json::member(root, "files");
    if list {
        json::each(list) { part =>
            let s, ok = json::as_string(part);
            if ok && s.len > 0 { resolved(s, files); files.push('\n'); }
        };
    }
    let rl = json::member(root, "references");
    if rl {
        json::each(rl) { part =>
            let s, ok = json::as_string(json::member(part, "path"));
            if ok && s.len > 0 {
                var p: u8[>..] = [];
                resolved(s, p);
                if is_dir(p) { p.append("/tsconfig.json"); }
                if file_exists(p) { refs.append(p); refs.push('\n'); }
            }
        };
    }
    return true;
}

// The files that a config other than `base` owns, as lines "config \t file"
// with each config's lines together. `nested` is every tsconfig.json below
// the repo's root; the configs they and `base` reference are followed.
// `base_files` is what `base` lists: a file it lists stays with it unless a
// config nearer the file lists it too. `note` gets a line for the report.
fn ts_other_projects(repo: const u8[:], out: const u8[:], trusted: bool, tsc: const u8[:], env: const u8[:],
                     base: const u8[:], base_files: const u8[:], nested: const u8[:], note: u8[>..]&) -> u8[>..] {
    var queue: u8[>..] = [];        // configs to ask, one per line; only grows
    fn enqueue(c: const u8[:]) {
        if c.len > 0 && c != base && !contains_line(queue, c) { queue.append(c); queue.push('\n'); }
    }
    fn ask(config: const u8[:], files: u8[>..]&, refs: u8[>..]&) -> bool {
        var a: u8[>..] = [];
        arg(a, tsc);
        arg(a, "-p");
        arg(a, config);
        arg(a, "--showConfig");
        var o: u8[>..] = [];
        var e: u8[>..] = [];
        guard sealed_run(a, repo, out, trusted, env, 120000, o, e) == 0 else { return false; }
        return ts_show_parse(o, ts_folder(config), files, refs);
    }
    let base_in_repo = starts_with(base, str(repo, "/"));
    if base_in_repo {
        var bf: u8[>..] = [];
        var br: u8[>..] = [];
        if ask(base, bf, br) { each_split(br, '\n') { r => enqueue(r) }; }
    }
    each_split(nested, '\n') { c => enqueue(c) };

    var configs: u8[>..] = [];      // those that answered, one per line
    var listed: u8[>..] = [];       // "index \t file" for every file one of them lists
    var n = 0;
    var unread = 0;
    var over = 0;
    var next = 0;
    while next < queue.len {
        let end = next + find(queue[next..], "\n");
        var config: u8[>..] = [];
        config.append(queue[next..end]);
        next = end + 1;
        if n >= TS_PROJECT_LIMIT { over++; continue; }
        var files: u8[>..] = [];
        var refs: u8[>..] = [];
        if !ask(config, files, refs) { unread++; continue; }
        each_split(refs, '\n') { r => enqueue(r) };
        format(configs, config, "\n");
        each_split(files, '\n') { f => if f.len > 0 { format(listed, n, "\t", f, "\n"); } };
        n++;
    }
    var others: u8[>..] = [];
    guard n > 0 else {
        if unread > 0 { format(note, "typescript: ", unread, " more tsconfig files could not be read by tsc; their files stay with the root's\n"); }
        return others;
    }
    let cfgs = split(configs[..configs.len - 1], '\n');
    // Who has each file now: -1 the root's config, else an index into cfgs.
    var owner = dictionary<u64, i64> {};
    each_split(base_files, '\n') { raw =>
        let f = trim(raw);
        if f.len > 0 {
            var real: u8[>..] = [];
            if !swan_realpath(f, real) { real.append(f); }
            owner.insert(hash(real[..]), -1);
        }
    };
    each_split(listed, '\n') { line =>
        let tab = find(line, "\t");
        guard tab > 0;
        let i, ok = parse_int(line[..tab]);
        let f = line[tab + 1..];
        let had = owner.get(hash(f));
        if !had { owner.insert(hash(f), i); }
        else {
            let old: i64 = had;
            let near_old = if old < 0 { if base_in_repo { ts_nearness(base, f) } else { 0 } } else { ts_nearness(cfgs[old], f) };
            let near_new = ts_nearness(cfgs[i], f);
            // In one folder its tsconfig.json comes before the configs that one references.
            let old_main = if old < 0 { base_in_repo } else { ends_with(cfgs[old], "/tsconfig.json") };
            if near_new > near_old || (near_new == near_old && !old_main && ends_with(cfgs[i], "/tsconfig.json")) { owner.insert(hash(f), i); }
        }
    };
    var given = dictionary<u64, bool> {};
    var owning = 0;
    var last = -1;
    each_split(listed, '\n') { line =>
        let tab = find(line, "\t");
        guard tab > 0;
        let i, ok = parse_int(line[..tab]);
        let f = line[tab + 1..];
        let has = owner.get(hash(f));
        guard has;
        let o: i64 = has;
        if o == i && !given.contains(hash(f)) {
            given.insert(hash(f), true);
            format(others, cfgs[i], "\t", f, "\n");
            if i != last { owning++; last = i; }
        }
    };
    format(note, "typescript: ", owning, " more tsconfig projects own files, each indexed under its own config");
    if unread > 0 { format(note, "; ", unread, " could not be read by tsc"); }
    if over > 0 { format(note, "; ", over, " past the limit of ", TS_PROJECT_LIMIT, " not asked"); }
    note.push('\n');
    return others;
}
