// The cargo projects of a repo. Carried over from src/rustproj.goose, with
// the toolchain helpers it uses from src/seal.goose.
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
// rust_unmapped (stage 4, with the map) names every crate that ended up with
// no rows.

use crate::sys;
use crate::util::{contains_line, find, json_string, parse_int, starts_with, trim};
use crate::walk::Walk;

// How many cargo projects one map indexes. Each is a rust-analyzer run that
// loads the standard library again, so a repo of hundreds of example crates
// would take hours. The rest are named in the report.
pub const RUST_PROJECT_LIMIT: usize = 12;

fn split_lines(s: &[u8]) -> impl Iterator<Item = &[u8]> {
    s.split(|&c| c == b'\n')
}

// rust-analyzer's settings for `scip --config-path`: every cargo feature on,
// so code behind #[cfg(feature = "...")] is resolved by the compiler front
// end (with the default features alone it had rows by name at best), and,
// when `std_src` is given, the standard library source to read (see
// rust_std_source below).
pub fn rust_analyzer_config(std_src: &[u8]) -> Vec<u8> {
    let mut c: Vec<u8> = Vec::new();
    c.extend_from_slice(b"{\"cargo\":{\"features\":\"all\"");
    if !std_src.is_empty() {
        c.extend_from_slice(b",\"sysrootSrc\":");
        json_string(&mut c, std_src);
    }
    c.extend_from_slice(b"}}\n");
    c
}

// Folder `rel` seen from folder `dir`, both as paths from the repo ("." is
// the repo itself), with "." and ".." worked out. "" when it leaves the repo.
pub fn cargo_join(dir: &[u8], rel: &[u8]) -> Vec<u8> {
    let mut parts: Vec<u8> = Vec::new(); // the segments so far, each followed by '/'
    let mut out_of_repo = false;
    let mut take = |path: &[u8], parts: &mut Vec<u8>| {
        for seg in path.split(|&c| c == b'/') {
            if seg.is_empty() || seg == b"." {
                // nothing
            } else if seg == b".." {
                if parts.is_empty() {
                    out_of_repo = true;
                } else {
                    let mut cut = parts.len() - 1;
                    while cut > 0 && parts[cut - 1] != b'/' {
                        cut -= 1;
                    }
                    parts.truncate(cut);
                }
            } else {
                parts.extend_from_slice(seg);
                parts.push(b'/');
            }
        }
    };
    if rel.is_empty() || rel[0] != b'/' {
        take(dir, &mut parts);
    }
    take(rel, &mut parts);
    if out_of_repo || (!rel.is_empty() && rel[0] == b'/') {
        return Vec::new();
    }
    if parts.is_empty() {
        return b".".to_vec();
    }
    parts[..parts.len() - 1].to_vec()
}

// Whether folder `d` lies inside folder `above`.
pub fn cargo_inside(d: &[u8], above: &[u8]) -> bool {
    if above == b"." {
        return d != b".";
    }
    d.len() > above.len() && starts_with(d, above) && d[above.len()] == b'/'
}

// What a Cargo.toml says about the folders around it. f(kind, path):
//   'w' once, with "", when it has a [workspace] table (its folder is then a
//       workspace root, whatever lies above it);
//   'x' for each folder its workspace excludes;
//   'p' for each `path = "..."` (a crate built together with this one; also
//       [lib] and [[bin]] source files, which name no folder with a manifest).
// Paths are as written, from the manifest's own folder. Read line by line:
// the manifests cargo itself writes and people keep by hand fit that.
fn cargo_manifest_facts(text: &[u8], mut f: impl FnMut(u8, &[u8])) {
    let mut section: Vec<u8> = Vec::new();
    let mut in_exclude = false;
    let mut said_w = false;
    for raw in split_lines(text) {
        let hash = find(raw, b"#");
        let t = trim(if hash >= 0 { &raw[..hash as usize] } else { raw });
        if !t.is_empty() && t[0] == b'[' {
            section.clear();
            section.extend_from_slice(t);
            in_exclude = false;
            if !said_w && (starts_with(t, b"[workspace]") || starts_with(t, b"[workspace.")) {
                said_w = true;
                f(b'w', b"");
            }
        } else if !t.is_empty() {
            let ws = starts_with(&section, b"[workspace]");
            if ws && starts_with(t, b"exclude") && find(t, b"=") > 0 {
                in_exclude = true;
            }
            if in_exclude {
                // The quoted strings of the array, which may run over lines.
                let mut p: usize = if starts_with(t, b"exclude") { (find(t, b"=") + 1) as usize } else { 0 };
                while p < t.len() {
                    let a = find(&t[p..], b"\"");
                    if a < 0 {
                        break;
                    }
                    let a = a as usize;
                    let b = find(&t[p + a + 1..], b"\"");
                    if b < 0 {
                        break;
                    }
                    let b = b as usize;
                    f(b'x', &t[p + a + 1..p + a + 1 + b]);
                    p = p + a + b + 2;
                }
                if find(t, b"]") >= 0 {
                    in_exclude = false;
                }
            } else {
                let mut p: usize = 0;
                while p < t.len() {
                    let a = find(&t[p..], b"path");
                    if a < 0 {
                        break;
                    }
                    let a = a as usize;
                    let mut q = p + a + 4;
                    let word = p + a == 0 || {
                        let c = t[p + a - 1];
                        !(c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
                    };
                    while q < t.len() && t[q] == b' ' {
                        q += 1;
                    }
                    if word && q < t.len() && t[q] == b'=' {
                        q += 1;
                        while q < t.len() && t[q] == b' ' {
                            q += 1;
                        }
                        if q < t.len() && t[q] == b'"' {
                            let b = find(&t[q + 1..], b"\"");
                            if b >= 0 {
                                let b = b as usize;
                                f(b'p', &t[q + 1..q + 1 + b]);
                                q = q + b + 2;
                            }
                        }
                    }
                    p = q.max(p + a + 4);
                }
            }
        }
    }
}

// Every folder of the repo with a Cargo.toml, as a path from the repo, one
// per line, shallowest first.
pub fn cargo_manifest_dirs(walk: &Walk, repo: &[u8]) -> Vec<u8> {
    let mut dirs: Vec<u8> = Vec::new();
    walk.each_file(repo, |full, name| {
        if name == b"Cargo.toml" {
            if full.len() == repo.len() + 1 + name.len() {
                dirs.extend_from_slice(b".\n");
            } else {
                dirs.extend_from_slice(&full[repo.len() + 1..full.len() - name.len() - 1]);
                dirs.push(b'\n');
            }
        }
    });
    dirs
}

fn push_line(out: &mut Vec<u8>, s: &[u8]) {
    out.extend_from_slice(s);
    out.push(b'\n');
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
pub fn rust_projects(repo: &[u8], dirs: &[u8], over: &mut Vec<u8>) -> Vec<u8> {
    let mut roots: Vec<u8> = Vec::new(); // folders whose manifest has a [workspace] table
    let mut excluded: Vec<u8> = Vec::new(); // folders some workspace excludes
    let mut by_path: Vec<u8> = Vec::new(); // folders some other manifest depends on by path
    for d in split_lines(dirs) {
        if d.is_empty() {
            continue;
        }
        let mut text: Vec<u8> = Vec::new();
        if !sys::read_file(&[repo, b"/", d, b"/Cargo.toml"].concat(), &mut text) {
            continue;
        }
        cargo_manifest_facts(&text, |kind, path| {
            if kind == b'w' {
                push_line(&mut roots, d);
            } else {
                let at = cargo_join(d, path);
                if !at.is_empty() && at != d {
                    if kind == b'x' {
                        push_line(&mut excluded, &at);
                    } else {
                        push_line(&mut by_path, &at);
                    }
                }
            }
        });
    }
    let mut plan: Vec<u8> = Vec::new();
    let mut n = 0;
    for d in split_lines(dirs) {
        if d.is_empty() {
            continue;
        }
        // some manifest lies above it
        let below = split_lines(dirs).any(|a| !a.is_empty() && cargo_inside(d, a));
        // some workspace root lies above it
        let in_workspace = split_lines(&roots).any(|a| !a.is_empty() && cargo_inside(d, a));
        // excluded itself, or inside an excluded folder
        let cut_off = split_lines(&excluded).any(|x| !x.is_empty() && (x == d || cargo_inside(d, x)));
        let own = !below
            || contains_line(&roots, d)
            || (in_workspace && cut_off)
            || (!in_workspace && !contains_line(&by_path, d));
        if own && n < RUST_PROJECT_LIMIT {
            push_line(&mut plan, d);
            n += 1;
        } else if own {
            push_line(over, d);
        }
    }
    plan
}

// The folder whose rust-toolchain file rustup would use for cargo run in
// project `dir`: the nearest one from the project up to the repo.
pub fn rust_toolchain_dir(repo: &[u8], dir: &[u8]) -> Vec<u8> {
    let mut at: Vec<u8> = dir.to_vec();
    while at != b"." {
        let full = [repo, b"/", &at[..]].concat();
        if sys::file_exists(&[&full[..], b"/rust-toolchain.toml"].concat())
            || sys::file_exists(&[&full[..], b"/rust-toolchain"].concat())
        {
            return full;
        }
        let up = cargo_join(&at, b"..");
        if up.is_empty() {
            break;
        }
        at = up;
    }
    repo.to_vec()
}

// ---- from src/seal.goose: which Rust toolchain the repo asks for ----

// $NAME when set and not empty, else $HOME/<sub>.
pub fn toolchain_home(name: &[u8], sub: &[u8]) -> Vec<u8> {
    let v = sys::env(name);
    if !v.is_empty() {
        return v;
    }
    [&sys::env(b"HOME")[..], b"/", sub].concat()
}

// Passes $VAR to a sealed child when this machine keeps that folder where
// toolchain_home says: $VAR is set, or $HOME/<sub> is there. Otherwise the
// variable is left alone. A machine with rustup installed for everyone has
// no ~/.rustup: its `cargo` is a small script that sets RUSTUP_HOME itself
// when nothing else did, and naming ~/.rustup made rustup try to create it
// inside the seal ("could not create home directory ... Read-only file
// system"), so every Rust map there failed (found 2026-11-17 in a clean
// Ubuntu microVM).
pub fn add_toolchain_env(renv: &mut Vec<Vec<u8>>, name: &[u8], sub: &[u8]) {
    let p = toolchain_home(name, sub);
    if !sys::env(name).is_empty() || sys::is_dir(&p) {
        renv.push([name, b"=", &p[..]].concat());
    }
}

// The channel a folder's rust-toolchain.toml or rust-toolchain pins
// (`channel = "1.88.0"`), else "".
fn rust_pinned_channel(dir: &[u8]) -> Vec<u8> {
    let mut text: Vec<u8> = Vec::new();
    let mut channel: Vec<u8> = Vec::new();
    if sys::read_file(&[dir, b"/rust-toolchain.toml"].concat(), &mut text) {
        for l in split_lines(&text) {
            let t = trim(l);
            if channel.is_empty() && starts_with(t, b"channel") && find(t, b"\"") >= 0 {
                let a = (find(t, b"\"") + 1) as usize;
                let b = a as i64 + find(&t[a..], b"\"");
                if b > a as i64 {
                    channel.extend_from_slice(&t[a..b as usize]);
                }
            }
        }
    } else if sys::read_file(&[dir, b"/rust-toolchain"].concat(), &mut text) {
        for l in split_lines(&text) {
            if channel.is_empty() && !trim(l).is_empty() && find(l, b"[") < 0 && find(l, b"=") < 0 {
                channel.extend_from_slice(trim(l));
            }
        }
    }
    channel
}

// Where rustup keeps toolchains: $RUSTUP_HOME or ~/.rustup, else what
// rustup itself says (installed for everyone, its home is elsewhere and
// only its wrapper scripts know). Asked from /, never from the repo:
// there rustup would try to install the pinned toolchain. "" when unknown.
fn rustup_home_dir() -> Vec<u8> {
    let rh = toolchain_home(b"RUSTUP_HOME", b".rustup");
    if sys::is_dir(&[&rh[..], b"/toolchains"].concat()) {
        return rh;
    }
    match sys::run_capture(&[b"rustup", b"show", b"home"], b"/", 10000) {
        Some((0, o)) => trim(&o).to_vec(),
        _ => Vec::new(),
    }
}

// Whether rustup (home `rh`) has the toolchain a channel names.
fn rustup_has(rh: &[u8], channel: &[u8]) -> bool {
    let names = match sys::list_dir(&[rh, b"/toolchains"].concat()) {
        Some(n) => n,
        None => return false,
    };
    let dash = [channel, b"-"].concat();
    names.iter().any(|n| n == channel || starts_with(n, &dash))
}

// rustup's default toolchain, else "".
fn rustup_default(rh: &[u8]) -> Vec<u8> {
    let mut settings: Vec<u8> = Vec::new();
    let mut dflt: Vec<u8> = Vec::new();
    if sys::read_file(&[rh, b"/settings.toml"].concat(), &mut settings) {
        for l in split_lines(&settings) {
            let t = trim(l);
            if dflt.is_empty() && starts_with(t, b"default_toolchain") && find(t, b"\"") >= 0 {
                let a = (find(t, b"\"") + 1) as usize;
                let b = a as i64 + find(&t[a..], b"\"");
                if b > a as i64 {
                    dflt.extend_from_slice(&t[a..b as usize]);
                }
            }
        }
    }
    dflt
}

// The N of a Rust version "1.N..." at the start of `text`, else -1.
fn rust_minor(text: &[u8]) -> i64 {
    if !starts_with(text, b"1.") {
        return -1;
    }
    let mut e = 2;
    while e < text.len() && text[e].is_ascii_digit() {
        e += 1;
    }
    parse_int(if e > 2 { &text[2..e] } else { b"x" }).unwrap_or(-1)
}

// The N of the Rust 1.N a toolchain of rustup's holds: from its name
// ("1.88.0-x86_64-...") or, for a named channel (stable), from the
// manifest rustup keeps beside it. -1 when neither says.
fn rustup_minor(rh: &[u8], toolchain: &[u8]) -> i64 {
    let by_name = rust_minor(toolchain);
    if by_name >= 0 {
        return by_name;
    }
    let mut manifest: Vec<u8> = Vec::new();
    if !sys::read_file(
        &[rh, b"/toolchains/", toolchain, b"/lib/rustlib/multirust-channel-manifest.toml"].concat(),
        &mut manifest,
    ) {
        return -1;
    }
    let at = find(&manifest, b"[pkg.rustc]");
    if at < 0 {
        return -1;
    }
    let at = at as usize;
    let v = find(&manifest[at..], b"version = \"");
    if v < 0 {
        return -1;
    }
    rust_minor(&manifest[at + v as usize + 11..])
}

// The toolchain to index with when the repo pins one rustup does not have
// (rust-toolchain.toml or rust-toolchain: `channel = "1.88.0"`): rustup's
// default one, else "". Without this cargo exits "toolchain ... is not
// installed" and the repo gets no Rust map at all; a sealed, offline run
// cannot install it, and a map does not need the exact compiler. Found on
// relatedb/relate, 2026-11-17.
pub fn rust_toolchain_override(repo: &[u8]) -> Vec<u8> {
    let channel = rust_pinned_channel(repo);
    if channel.is_empty() {
        return Vec::new();
    }
    let rh = rustup_home_dir();
    if !(!rh.is_empty() && sys::is_dir(&[&rh[..], b"/toolchains"].concat()) && !rustup_has(&rh, &channel)) {
        return Vec::new();
    }
    let dflt = rustup_default(&rh);
    if dflt.is_empty() {
        return Vec::new();
    }
    sys::write_stderr(
        &[&b"rust: the repo pins toolchain "[..], &channel, b", which is not installed; indexing with ", &dflt, b"\n"].concat(),
    );
    dflt
}

// The standard library source rust-analyzer should read (its
// cargo.sysrootSrc) when the repo pins an installed Rust 1.N older than
// rustup's default toolchain: the default one's, else "". Swan's
// rust-analyzer is a recent build and follows the current library; given
// Rust 1.88's own (relate, 2026-11-17) it loaded core but resolved no
// macro_rules macro of it (matches!, vec!, assert_eq!) and nothing from the
// prelude (Some, slice methods), so every use inside those macros was by
// name at best. Cargo, build scripts and proc macros still run with the
// pinned toolchain.
pub fn rust_std_source(repo: &[u8]) -> Vec<u8> {
    let channel = rust_pinned_channel(repo);
    let pinned = rust_minor(&channel);
    if pinned < 0 {
        return Vec::new();
    }
    let rh = rustup_home_dir();
    if !(!rh.is_empty() && rustup_has(&rh, &channel)) {
        return Vec::new();
    }
    let dflt = rustup_default(&rh);
    if !(!dflt.is_empty() && rustup_minor(&rh, &dflt) > pinned) {
        return Vec::new();
    }
    let src = [&rh[..], b"/toolchains/", &dflt, b"/lib/rustlib/src/rust/library"].concat();
    if !sys::file_exists(&[&src[..], b"/core/src/lib.rs"].concat()) {
        return Vec::new();
    }
    sys::write_stderr(
        &[
            &b"rust: the repo pins toolchain "[..],
            &channel,
            b"; its standard library is read from ",
            &dflt,
            b", which Swan's rust-analyzer follows (cargo and build scripts still run with ",
            &channel,
            b")\n",
        ]
        .concat(),
    );
    src
}

// `swan cargo-projects <repo>`: what swan map would do for Rust here, run
// nothing. One line for each project, "folder \t rust-analyzer's settings
// \t toolchain", the toolchain only when it is not the one the repo asks
// for; then the projects past the limit, as "not mapped \t folder".
pub fn cargo_projects_report(repo: &[u8]) -> Vec<u8> {
    let walk = Walk::default();
    let mut out: Vec<u8> = Vec::new();
    let mut over: Vec<u8> = Vec::new();
    let plan = rust_projects(repo, &cargo_manifest_dirs(&walk, repo), &mut over);
    for dir in split_lines(&plan) {
        if dir.is_empty() {
            continue;
        }
        let tc_dir = rust_toolchain_dir(repo, dir);
        out.extend_from_slice(dir);
        out.push(b'\t');
        out.extend_from_slice(trim(&rust_analyzer_config(&rust_std_source(&tc_dir))));
        out.push(b'\t');
        out.extend_from_slice(&rust_toolchain_override(&tc_dir));
        out.push(b'\n');
    }
    for dir in split_lines(&over) {
        if !dir.is_empty() {
            out.extend_from_slice(b"not mapped\t");
            out.extend_from_slice(dir);
            out.push(b'\n');
        }
    }
    out
}
