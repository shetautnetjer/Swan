// The cargo projects of a repo.
//
// `rust-analyzer scip <folder>` loads one cargo workspace: the one whose
// Cargo.toml is in that folder. A repo can hold more than one: a fuzz or
// xtask crate cut off from the workspace above it by a [workspace] table of
// its own, a crate the workspace excludes, or several crates side by side
// with no Cargo.toml at the repo root. Each gets a run of its own. Before
// 2026-11-17 only the repo root's workspace was mapped and the rest had no
// rows at all (relate's surfaces/relate-ffi/fuzz), with nothing saying so.
//
// Which folder is a project is read from the Cargo.toml files alone, the way
// cargo decides it, without running cargo: that would run in the repo before
// the map's sealed jobs do. What the reading gets wrong is caught afterwards:
// rust_unmapped names every crate that ended up with no rows.

import std;
import os;
import json;
import sqlite;

// How many cargo projects one map indexes. Each is a rust-analyzer run that
// loads the standard library again, so a repo of hundreds of example crates
// would take hours. The rest are named in the report.
let RUST_PROJECT_LIMIT = 12;

// rust-analyzer's settings for `scip --config-path`: every cargo feature on,
// so code behind #[cfg(feature = "...")] is resolved by the compiler front
// end (with the default features alone it had rows by name at best), and,
// when `std_src` is given, the standard library source to read (see
// rust_std_source in src/seal.goose).
fn rust_analyzer_config(std_src: const u8[:]) -> u8[>..] {
    var c: u8[>..] = [];
    c.append("{\"cargo\":{\"features\":\"all\"");
    if std_src.len > 0 {
        c.append(",\"sysrootSrc\":");
        json::format_string(c, std_src);
    }
    c.append("}}\n");
    return c;
}

// Folder `rel` seen from folder `dir`, both as paths from the repo ("." is
// the repo itself), with "." and ".." worked out. "" when it leaves the repo.
fn cargo_join(dir: const u8[:], rel: const u8[:]) -> u8[>..] {
    var parts: u8[>..] = [];        // the segments so far, each followed by '/'
    var out_of_repo = false;
    fn take(path: const u8[:]) {
        each_split(path, '/') { seg =>
            if seg.len == 0 || seg == "." {
                // nothing
            } else if seg == ".." {
                if parts.len == 0 { out_of_repo = true; }
                else {
                    var cut = parts.len - 1;
                    while cut > 0 && parts[cut - 1] != '/' { cut--; }
                    var kept: u8[>..] = [];
                    kept.append(parts[..cut]);
                    parts.clear();
                    parts.append(kept);
                }
            } else {
                parts.append(seg);
                parts.push('/');
            }
        };
    }
    if rel.len == 0 || rel[0] != '/' { take(dir); }
    take(rel);
    var none: u8[>..] = [];
    guard !out_of_repo && !(rel.len > 0 && rel[0] == '/') else { return none; }
    guard parts.len > 0 else { return str("."); }
    return str(parts[..parts.len - 1]);
}

// Whether folder `d` lies inside folder `above`.
fn cargo_inside(d: const u8[:], above: const u8[:]) -> bool {
    if above == "." { return d != "."; }
    return d.len > above.len && starts_with(d, above) && d[above.len] == '/';
}

// What a Cargo.toml says about the folders around it. F(kind, path):
//   'w' once, with "", when it has a [workspace] table (its folder is then a
//       workspace root, whatever lies above it);
//   'x' for each folder its workspace excludes;
//   'p' for each `path = "..."` (a crate built together with this one; also
//       [lib] and [[bin]] source files, which name no folder with a manifest).
// Paths are as written, from the manifest's own folder. Read line by line:
// the manifests cargo itself writes and people keep by hand fit that.
fn cargo_manifest_facts<F>(text: const u8[:]) {
    var section: u8[>..] = [];
    var in_exclude = false;
    var said_w = false;
    each_split(text, '\n') { raw =>
        let hash = find(raw, "#");
        let t = trim(if hash >= 0 { raw[..hash] } else { raw });
        if t.len > 0 && t[0] == '[' {
            section.clear();
            section.append(t);
            in_exclude = false;
            if !said_w && (starts_with(t, "[workspace]") || starts_with(t, "[workspace.")) { said_w = true; F('w', ""); }
        } else if t.len > 0 {
            let ws = starts_with(section, "[workspace]");
            if ws && starts_with(t, "exclude") && find(t, "=") > 0 { in_exclude = true; }
            if in_exclude {
                // The quoted strings of the array, which may run over lines.
                var p = if starts_with(t, "exclude") { find(t, "=") + 1 } else { 0 };
                while p < t.len {
                    let a = find(t[p..], "\"");
                    guard a >= 0 else { break; }
                    let b = find(t[p + a + 1..], "\"");
                    guard b >= 0 else { break; }
                    F('x', t[p + a + 1..p + a + 1 + b]);
                    p = p + a + b + 2;
                }
                if find(t, "]") >= 0 { in_exclude = false; }
            } else {
                var p = 0;
                while p < t.len {
                    let a = find(t[p..], "path");
                    guard a >= 0 else { break; }
                    var q = p + a + 4;
                    let word = p + a == 0 || !(is_alnum(t[p + a - 1]) || t[p + a - 1] == '_' || t[p + a - 1] == '-');
                    while q < t.len && t[q] == ' ' { q++; }
                    if word && q < t.len && t[q] == '=' {
                        q++;
                        while q < t.len && t[q] == ' ' { q++; }
                        if q < t.len && t[q] == '"' {
                            let b = find(t[q + 1..], "\"");
                            if b >= 0 { F('p', t[q + 1..q + 1 + b]); q = q + b + 2; }
                        }
                    }
                    p = max(q, p + a + 4);
                }
            }
        }
    };
}

// Every folder of the repo with a Cargo.toml, as a path from the repo, one
// per line, shallowest first.
fn cargo_manifest_dirs(repo: const u8[:]) -> u8[>..] {
    var dirs: u8[>..] = [];
    each_file(repo) { full, name =>
        if name == "Cargo.toml" {
            if full.len == repo.len + 1 + name.len { dirs.append(".\n"); }
            else { format(dirs, full[repo.len + 1..full.len - name.len - 1], "\n"); }
        }
    };
    return dirs;
}

// The folders to run rust-analyzer in, one per line. A folder with a
// Cargo.toml is a project of its own when
//   - no folder above it has one, or
//   - its Cargo.toml has a [workspace] table, or
//   - the nearest workspace above it excludes it, or
//   - no folder above it is a workspace and no other Cargo.toml in the repo
//     names it as a `path` dependency (cargo then builds it alone).
// The other folders are crates built as part of a project above them.
// Projects past RUST_PROJECT_LIMIT go to `over`.
fn rust_projects(repo: const u8[:], dirs: const u8[:], over: u8[>..]&) -> u8[>..] {
    var roots: u8[>..] = [];        // folders whose manifest has a [workspace] table
    var excluded: u8[>..] = [];     // folders some workspace excludes
    var by_path: u8[>..] = [];      // folders some other manifest depends on by path
    each_split(dirs, '\n') { d =>
        guard d.len > 0;
        var text: u8[>..] = [];
        guard read_file(str(repo, "/", d, "/Cargo.toml"), text);
        cargo_manifest_facts(text) { kind, path =>
            if kind == 'w' { format(roots, d, "\n"); }
            else {
                let at = cargo_join(d, path);
                if at.len > 0 && at != d {
                    if kind == 'x' { format(excluded, at, "\n"); } else { format(by_path, at, "\n"); }
                }
            }
        };
    };
    var plan: u8[>..] = [];
    var n = 0;
    each_split(dirs, '\n') { d =>
        guard d.len > 0;
        var below = false;          // some manifest lies above it
        var in_workspace = false;   // some workspace root lies above it
        each_split(dirs, '\n') { a => if a.len > 0 && cargo_inside(d, a) { below = true; } };
        each_split(roots, '\n') { a => if a.len > 0 && cargo_inside(d, a) { in_workspace = true; } };
        var cut_off = false;        // excluded itself, or inside an excluded folder
        each_split(excluded, '\n') { x => if x.len > 0 && (x == d || cargo_inside(d, x)) { cut_off = true; } };
        let own = !below || contains_line(roots, d) || (in_workspace && cut_off) ||
                  (!in_workspace && !contains_line(by_path, d));
        if own && n < RUST_PROJECT_LIMIT { format(plan, d, "\n"); n++; }
        else if own { format(over, d, "\n"); }
    };
    return plan;
}

// The folder whose rust-toolchain file rustup would use for cargo run in
// project `dir`: the nearest one from the project up to the repo.
fn rust_toolchain_dir(repo: const u8[:], dir: const u8[:]) -> u8[>..] {
    var at: u8[>..] = [];
    at.append(dir);
    while at != "." {
        let full = str(repo, "/", at);
        if file_exists(str(full, "/rust-toolchain.toml")) || file_exists(str(full, "/rust-toolchain")) { return full; }
        let up = cargo_join(at, "..");
        guard up.len > 0 else { break; }
        at.clear();
        at.append(up);
    }
    return str(repo);
}

// The crates of the repo that the map has no rows for, as "dir, dir, ..."
// (five at most, then a count): every folder whose Cargo.toml names a
// package and which has Rust files of its own, none of them in the map's
// `files`. Read from the
// finished map, so it holds whatever the reason was: a project past the
// limit, one whose run failed, or a crate that turned out to be in no
// project that was run.
fn rust_unmapped(repo: const u8[:], db_path: const u8[:], dirs: const u8[:]) -> u8[>..] {
    var none: u8[>..] = [];
    var err: u8[>..] = [];
    let db = sqlite::open_existing(db_path, err);
    guard db != 0 else { return none; }
    // The crate a file belongs to: the deepest folder with a Cargo.toml above it.
    fn crate_of(file: const u8[:], best: u8[>..]&) {
        best.clear();
        each_split(dirs, '\n') { d =>
            let above = d == "." || (file.len > d.len && starts_with(file, d) && file[d.len] == '/');
            if d.len > 0 && above && (best.len == 0 || best == "." || (d != "." && d.len > best.len)) {
                best.clear();
                best.append(d);
            }
        };
    }
    var mapped: u8[>..] = [];       // crates with a Rust file in the map
    var c: u8[>..] = [];
    var file: u8[>..] = [];
    let q = sqlite::prepare(db, "SELECT file FROM files WHERE file LIKE '%.rs'", err);
    if q != 0 {
        while sqlite::step(q, err) == 1 {
            file.clear();
            sqlite::col_text(q, 0, file);
            crate_of(file, c);
            if c.len > 0 && !contains_line(mapped, c) { format(mapped, c, "\n"); }
        }
        sqlite::finalize(q);
    }
    sqlite::close(db);
    var holding: u8[>..] = [];      // crates with a Rust file on disk
    each_file(repo) { full, name =>
        if ends_with(name, ".rs") {
            crate_of(full[repo.len + 1..], c);
            if c.len > 0 && !contains_line(holding, c) { format(holding, c, "\n"); }
        }
    };
    var list: u8[>..] = [];
    var n = 0;
    each_split(holding, '\n') { h =>
        guard h.len > 0 && !contains_line(mapped, h);
        // A Cargo.toml with no [package] is a workspace's list of members, not
        // a crate: Rust files beside it (scripts, snippets in docs) belong to none.
        var manifest: u8[>..] = [];
        read_file(str(repo, "/", h, "/Cargo.toml"), manifest);
        guard starts_with(manifest, "[package") || find(manifest, "\n[package") >= 0;
        if n < 5 { format(list, if n > 0 { ", " } else { "" }, h); }
        n++;
    };
    if n > 5 { format(list, " and ", n - 5, " more"); }
    return list;
}

// `swan cargo-projects <repo>`: what swan map would do for Rust here, run
// nothing. One line for each project, "folder \t rust-analyzer's settings
// \t toolchain", the toolchain only when it is not the one the repo asks
// for; then the projects past the limit, as "not mapped \t folder".
fn cargo_projects_report(repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var over: u8[>..] = [];
    let plan = rust_projects(repo, cargo_manifest_dirs(repo), over);
    each_split(plan, '\n') { dir =>
        guard dir.len > 0;
        let tc_dir = rust_toolchain_dir(repo, dir);
        format(out, dir, "\t", trim(rust_analyzer_config(rust_std_source(tc_dir))), "\t", rust_toolchain_override(tc_dir), "\n");
    };
    each_split(over, '\n') { dir => if dir.len > 0 { format(out, "not mapped\t", dir, "\n"); } };
    return out;
}
