// The map: what `swan map` runs, in what order, and what it keeps.
//
// Carried over from src/pipeline.goose so far: `swan trust`, and the head of
// `swan map` (what git ignores, what the repo holds, its survey, an older
// or a clean map). The walk at the head of that file is in walk.rs. A map
// stops where the carrying has got to, with what it would have said so far
// and exit 70.

use std::collections::{HashMap, HashSet};

use crate::change::{code_hash, cosmetic_lang, index_lines, line_of_path};
use crate::db::Db;
use crate::index::SCHEMA_VERSION;
use crate::query::meta_value;
use crate::run::{run_step, swan_home};
use crate::stamp::prestamp;
use crate::survey::{survey_ignored, survey_report, survey_run};
use crate::sys;
use crate::treesitter;
use crate::util::{contains_line, ends_with, find, hash, parse_int, print, push_int, split, starts_with};
use crate::walk::Walk;

// What a repo holds, found by walking it.
#[derive(Default)]
struct Langs {
    ts: bool,
    js: bool,
    py: bool,
    rs: bool,
    java: bool,
    c: bool,
    cuda: bool,
    kt: bool,       // Kotlin: tree-sitter only for now, no SCIP indexer runs
    syn: bool,      // Go, shell, Make, Ruby or Lua: `swan syntax-index` maps them
    other: Vec<u8>, // languages with no indexer here, only search and live errors: "lua glsl ..."
    cargo: bool,
    venv: Vec<u8>, // a virtualenv inside the repo, if any
}

// Files `swan syntax-index` (src/syntax.rs) covers: Go, shell, Make, Ruby and Lua by name,
// and scripts with no extension in a bin/ or scripts/ folder (it reads their
// #! line itself).
fn syntax_file(full: &[u8], name: &[u8]) -> bool {
    for e in [&b".go"[..], b".sh", b".bash", b".zsh", b".ksh", b".rb", b".lua", b".mk"] {
        if ends_with(name, e) {
            return true;
        }
    }
    if name == b"Makefile" || name == b"makefile" || name == b"GNUmakefile" || name == b"Rakefile" {
        return true;
    }
    find(name, b".") < 0 && (find(full, b"/bin/") >= 0 || find(full, b"/scripts/") >= 0)
}

fn is_c_source(name: &[u8]) -> bool {
    ends_with(name, b".c") || ends_with(name, b".cc") || ends_with(name, b".cpp") || ends_with(name, b".cxx")
}

// One more name in `other`, which holds at most 255 bytes.
fn other_add(other: &mut Vec<u8>, lang: &[u8], room: usize) {
    if other.len() + room < 256 {
        if !other.is_empty() {
            other.push(b' ');
        }
        other.extend_from_slice(lang);
    }
}

fn detect(walk: &Walk, repo: &[u8]) -> Langs {
    let mut l = Langs { cargo: sys::file_exists(&[repo, b"/Cargo.toml"].concat()), ..Default::default() };
    for v in [&b".venv"[..], b"venv"] {
        if l.venv.is_empty() && sys::file_exists(&[repo, b"/", v, b"/pyvenv.cfg"].concat()) {
            l.venv = [repo, b"/", v].concat();
        }
    }
    walk.each_file(repo, |full, name| {
        if syntax_file(full, name) {
            l.syn = true;
        }
        if ends_with(name, b".ts") || ends_with(name, b".tsx") || ends_with(name, b".mts") || ends_with(name, b".cts") {
            l.ts = true;
        } else if ends_with(name, b".js") || ends_with(name, b".jsx") || ends_with(name, b".mjs") || ends_with(name, b".cjs") {
            l.js = true;
        } else if ends_with(name, b".py") {
            l.py = true;
        } else if ends_with(name, b".rs") {
            l.rs = true;
        } else if ends_with(name, b".java") {
            l.java = true;
        } else if ends_with(name, b".kt") || ends_with(name, b".kts") {
            l.kt = true;
        } else if ends_with(name, b".cu") || ends_with(name, b".cuh") {
            l.cuda = true;
        } else if is_c_source(name) || ends_with(name, b".h") || ends_with(name, b".hpp") || ends_with(name, b".hh") {
            l.c = true;
        } else if ends_with(name, b".go") {
            // Mapped through gopls when it is installed (tools/modules.json
            // "map": "lsp"); by syntax otherwise (syntax_file above).
            if find(&[b" ", &l.other[..], b" "].concat(), b" go ") < 0 {
                other_add(&mut l.other, b"go", 3);
            }
        } else if ends_with(name, b".goose") {
            // No grammar and no SCIP indexer: mapped through its language
            // server (tools/modules.json "map": "lsp").
            if find(&l.other, b"goose") < 0 {
                other_add(&mut l.other, b"goose", 6);
            }
        } else {
            // Any other language with a grammar here (Lua, the shaders,
            // GDScript, C#, PHP): no SCIP indexer runs for these (yet); they
            // are searched by structure and checked by their language servers.
            let lang = treesitter::language_of_path(name);
            let indexed = [&b"typescript"[..], b"tsx", b"javascript", b"python", b"rust", b"java", b"kotlin", b"c", b"cpp", b"cuda"].contains(&lang);
            if !lang.is_empty() && !indexed && find(&l.other, lang) < 0 {
                other_add(&mut l.other, lang, lang.len() + 1);
            }
        }
    });
    l
}

// Some indexers and checkers run the repo's own build files: cargo's build
// scripts and proc macros, Maven and Gradle, MSBuild through `dotnet
// restore`. A repo can run any code that way, so they wait until a person
// says the repo is trusted: `swan trust <repo>` adds the repo's
// path to Swan's own data/trusted-repos, which no repo can ship (a record
// inside the map folder could, when that folder sits in the checkout).
// SWAN_TRUST_BUILD=1 trusts every repo, for tests and CI. Nothing in the
// MCP server writes it.
fn trust_file() -> Vec<u8> {
    [&swan_home()[..], b"/data/trusted-repos"].concat()
}

fn build_trusted(repo: &[u8]) -> bool {
    if sys::env(b"SWAN_TRUST_BUILD") == b"1" {
        return true;
    }
    let mut saved: Vec<u8> = Vec::new();
    if !sys::read_file(&trust_file(), &mut saved) {
        return false;
    }
    contains_line(&saved, repo)
}

pub fn trust_main(repo_arg: &[u8], report: &mut Vec<u8>) -> bool {
    let repo = crate::abs_path(repo_arg);
    let tf = trust_file();
    let data = [&swan_home()[..], b"/data"].concat();
    let mut ignored: Vec<u8> = Vec::new();
    run_step(b"mkdir", &[b"mkdir", b"-p", &data], b"", &[], 10000, &mut ignored);
    let mut saved: Vec<u8> = Vec::new();
    sys::read_file(&tf, &mut saved);
    if !contains_line(&saved, &repo) {
        if !saved.is_empty() && saved[saved.len() - 1] != b'\n' {
            saved.push(b'\n');
        }
        saved.extend_from_slice(&repo);
        saved.push(b'\n');
        if !sys::write_file(&tf, &saved) {
            report.extend_from_slice(b"could not write ");
            report.extend_from_slice(&tf);
            return false;
        }
    }
    report.extend_from_slice(b"trusted ");
    report.extend_from_slice(&repo);
    report.extend_from_slice(b": swan map, swan check and live answers may now run its build files (Cargo, Maven, Gradle, MSBuild)");
    true
}

// Content stamps (src/change.rs): what a file holds, not when it was
// saved. content-stamps.tsv keeps one line per file stamped, "path\tsize\t
// mtime\tstamp\traw\tc|b" (c: stamped by its code alone, b: by its bytes),
// so a file whose size and mtime are what the last map saw is not read
// again. The text of each file stamped by its code is kept in texts/, by
// its raw hash, to move its rows after a cosmetic edit.
#[allow(dead_code)] // the lines and the times are read by the parts of the map still to be carried
struct Stamps {
    repo: Vec<u8>,
    texts_dir: Vec<u8>,
    prev: Vec<u8>, // content-stamps.tsv as the last map left it
    prev_at: HashMap<u64, usize>,
    lines: Vec<u8>,
    stamp_memo: HashMap<u64, u64>, // by the hash of the path
    raw_memo: HashMap<u64, u64>,
    mtime_memo: HashMap<u64, i64>,
    code_memo: HashSet<u64>, // the files stamped by their code
    // Stamps worked out ahead on several cores (prestamp), in the same
    // format as content-stamps.tsv and checked the same way.
    pre: Vec<u8>,
    pre_at: HashMap<u64, usize>,
}

impl Stamps {
    // What a stamp line says of a file, when its size and time are these.
    fn known(line: &[u8], size: i64, mt: i64) -> Option<(u64, u64, bool)> {
        if line.is_empty() {
            return None;
        }
        let f = split(line, b'\t');
        if f.len() == 6 && f[1] == size.to_string().as_bytes() && f[2] == mt.to_string().as_bytes() {
            if let (Some(a), Some(b)) = (parse_int(f[3]), parse_int(f[4])) {
                return Some((a as u64, b as u64, f[5] == b"c"));
            }
        }
        None
    }

    fn stamp(&mut self, full: &[u8]) -> u64 {
        let repo_len = self.repo.len();
        if !(full.len() > repo_len + 1 && starts_with(full, &self.repo) && full[repo_len] == b'/') {
            return hash(full);
        }
        let rel = &full[repo_len + 1..];
        let key = hash(rel);
        if let Some(&m) = self.stamp_memo.get(&key) {
            return m;
        }
        let size = sys::file_size(full);
        let mt = sys::mtime_ns(full);
        let mut found = Self::known(line_of_path(&self.prev, &self.prev_at, rel), size, mt);
        if found.is_none() && !self.pre.is_empty() {
            found = Self::known(line_of_path(&self.pre, &self.pre_at, rel), size, mt);
        }
        let (st, raw, by_code) = match found {
            Some(known) => known,
            None => {
                let mut text: Vec<u8> = Vec::new();
                sys::read_file(full, &mut text);
                let raw = hash(&text);
                let mut st = raw;
                let mut by_code = false;
                let lang = cosmetic_lang(rel);
                if !lang.is_empty() {
                    let (h, ok) = code_hash(lang, &text);
                    if ok {
                        st = h;
                        by_code = true;
                        let mut keep = [&self.texts_dir[..], b"/t"].concat();
                        push_int(&mut keep, raw as i64);
                        keep.extend_from_slice(b".txt");
                        if !sys::file_exists(&keep) {
                            sys::write_file(&keep, &text);
                        }
                    }
                }
                (st, raw, by_code)
            }
        };
        self.lines.extend_from_slice(rel);
        for v in [size, mt, st as i64, raw as i64] {
            self.lines.push(b'\t');
            push_int(&mut self.lines, v);
        }
        self.lines.extend_from_slice(if by_code { b"\tc\n" } else { b"\tb\n" });
        self.stamp_memo.insert(key, st);
        self.raw_memo.insert(key, raw);
        self.mtime_memo.insert(key, mt);
        if by_code {
            self.code_memo.insert(key);
        }
        st
    }

    fn raw_text_of(&self, key: u64) -> Vec<u8> {
        match self.raw_memo.get(&key) {
            Some(&r) => (r as i64).to_string().into_bytes(),
            None => Vec::new(),
        }
    }

    fn have_text(&self, raw: &[u8]) -> bool {
        !raw.is_empty() && raw != b"?" && sys::file_exists(&[&self.texts_dir[..], b"/t", raw, b".txt"].concat())
    }
}

pub fn map_main(repo_arg: &[u8], out_arg: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    let repo = crate::abs_path(repo_arg);
    let mut ignored: Vec<u8> = Vec::new();
    run_step(b"mkdir", &[b"mkdir", b"-p", out_arg], b"", &[], 10000, &mut ignored);
    let out = crate::abs_path(out_arg);
    let writer = match sys::WriterLock::acquire(&[&out[..], b"/swan.db"].concat()) {
        Ok(w) => w,
        Err(e) => {
            report.extend_from_slice(&e);
            return false;
        }
    };
    let ok = map_main_locked(&repo, &out, report, clean);
    if ok {
        writer.complete();
    } else {
        writer.unlock();
    }
    ok
}

// The public wrapper holds the writer lock for every shared output: cached
// indexer files, flattened rows, schema replacement and final database update.
fn map_main_locked(repo: &[u8], out: &[u8], report: &mut Vec<u8>, clean: bool) -> bool {
    let trusted = build_trusted(repo);
    // Before any walk of the repo: the folders git ignores are left out.
    let mut walk = Walk::default();
    let mut ignored_said: Vec<u8> = Vec::new();
    walk.refresh(repo, out, trusted, &mut ignored_said);
    let mut l = detect(&walk, repo);
    // A virtualenv inside the repo is the repo's own code (its python, its pip, its PATH):
    // run it only once the repo is trusted, like any other build-running step.
    // Until then it is read and not run (the Python step below).
    if !trusted {
        l.venv.clear();
    }
    // The projects the repo holds (src/survey.rs): read by Spread-Wings,
    // nothing of the repo run.
    let mut survey_why: Vec<u8> = Vec::new();
    let survey = survey_run(repo, out, &mut survey_why);
    report.extend_from_slice(b"languages:");
    let said: [(bool, &[u8]); 9] = [
        (l.ts, b" typescript"),
        (l.js, b" javascript"),
        (l.java, b" java"),
        (l.c, b" c/c++"),
        (l.cuda, b" cuda"),
        (l.py, b" python"),
        (l.rs || l.cargo, b" rust"),
        (l.kt, b" kotlin"),
        (l.syn, b" go/shell/make/ruby/lua (syntax only)"),
    ];
    for (there, name) in said {
        if there {
            report.extend_from_slice(name);
        }
    }
    if !l.other.is_empty() {
        report.push(b' ');
        report.extend_from_slice(&l.other);
    }
    if !l.venv.is_empty() {
        report.extend_from_slice(&[b" (venv ", &l.venv[..], b")"].concat());
    }
    report.push(b'\n');
    report.extend_from_slice(&ignored_said);
    let survey_skip = survey_ignored(out);
    if !survey.is_empty() {
        survey_report(&survey, &survey_skip, report);
    } else {
        report.extend_from_slice(&[b"projects: not surveyed (", &survey_why[..], b"): the map assumes what it did before, one Go project at the top\n"].concat());
    }
    // A map from an older Swan is rebuilt from scratch, indexers included:
    // reusing their output would skip what the new schema needs.
    let old_db = [out, b"/swan.db"].concat();
    if clean && sys::file_exists(&old_db) {
        // Refuse a wrong or unverifiable target before invalidating anything.
        // A damaged map can instead be rebuilt in a new private directory.
        let h = match Db::open_existing(&old_db) {
            Ok(h) => h,
            Err(e) => {
                report.extend_from_slice(&[b"cannot verify clean map target: ", &e[..]].concat());
                return false;
            }
        };
        let mut recorded: Vec<u8> = Vec::new();
        if let Ok(st) = h.prepare(b"SELECT value FROM meta WHERE key = 'root'") {
            if st.step().unwrap_or(false) {
                recorded = st.col_text(0);
            }
        }
        drop(h);
        if recorded != repo {
            report.extend_from_slice(&[&b"clean rebuild requires the exact recorded repo root; requested "[..], repo, b", recorded ", if !recorded.is_empty() { &recorded[..] } else { &b"(unreadable)"[..] }].concat());
            return false;
        }
    }
    if !clean && sys::file_exists(&old_db) {
        let h = match Db::open_existing(&old_db) {
            Ok(h) => h,
            Err(e) => crate::util::die(&[b"swan: cannot inspect map schema: ", &e[..]].concat()),
        };
        let v = meta_value(&h, b"schema_version");
        drop(h);
        if v != SCHEMA_VERSION.to_string().as_bytes() {
            report.extend_from_slice(&[&b"map schema "[..], if !v.is_empty() { &v[..] } else { &b"?"[..] }, b" is older than "].concat());
            push_int(report, SCHEMA_VERSION);
            report.extend_from_slice(b": rebuilding\n");
            for f in [&b"/swan.db"[..], b"/index-manifest.tsv", b"/python-pieces.tsv", b"/python-files.tsv"] {
                sys::delete_file(&[out, f].concat());
            }
        }
    }
    // Invalidate reuse metadata under the same stable writer lock. Never remove
    // the database or its lock: readers keep their snapshot until atomic publish.
    // Defer replacement metadata until publication, so failure/interruption
    // cannot make a later ordinary map trust unfinished indexer output.
    if clean {
        for name in [
            &b"index-manifest.tsv"[..],
            b"tsc-files.txt",
            b"tsc-program.txt",
            b"tsc-projects.txt",
            b"typescript-chunks.txt",
            b"typescript-shared.txt",
            b"typescript-files.tsv",
            b"typescript-layers.txt",
            b"python-files.tsv",
            b"python-pieces.tsv",
        ] {
            let path = [out, b"/", name].concat();
            if !(!sys::file_exists(&path) || sys::delete_file(&path)) {
                report.extend_from_slice(&[b"cannot invalidate clean rebuild cache: ", &path[..]].concat());
                return false;
            }
        }
        report.extend_from_slice(b"clean rebuild: cached indexer output and merge layers will not be reused; previous database retained until publication\n");
    }
    // Edits after this moment make answers stale (src/fresh.rs).
    sys::write_file(&[out, b"/scip-started"].concat(), b"");

    let texts_dir = [out, b"/texts"].concat();
    sys::make_dir(&texts_dir);
    let mut stamps = Stamps {
        repo: repo.to_vec(),
        texts_dir: texts_dir.clone(),
        prev: Vec::new(),
        prev_at: HashMap::new(),
        lines: Vec::new(),
        stamp_memo: HashMap::new(),
        raw_memo: HashMap::new(),
        mtime_memo: HashMap::new(),
        code_memo: HashSet::new(),
        pre: Vec::new(),
        pre_at: HashMap::new(),
    };
    if !clean {
        sys::read_file(&[out, b"/content-stamps.tsv"].concat(), &mut stamps.prev);
    }
    index_lines(&stamps.prev, &mut stamps.prev_at);

    // Cosmetic edits. indexed-texts.tsv says, for each file stamped by its
    // code, which text its rows were indexed from: "path\traw\tstamp", raw
    // "?" when Swan cannot tell. row-basis.tsv lists the files whose rows
    // Swan moved since the map was last written from indexer output:
    // "path\traw\tmtime", the text the rows now match and the mtime recorded
    // with it. A file whose rows could not be moved to match its text is
    // reindexed (`forced`), whatever its stamp says.
    let mut idx_prev: Vec<u8> = Vec::new();
    let mut basis_prev: Vec<u8> = Vec::new();
    if !clean {
        sys::read_file(&[out, b"/indexed-texts.tsv"].concat(), &mut idx_prev);
        sys::read_file(&[out, b"/row-basis.tsv"].concat(), &mut basis_prev);
    }
    let mut idx_at: HashMap<u64, usize> = HashMap::new();
    let mut basis_at: HashMap<u64, usize> = HashMap::new();
    index_lines(&idx_prev, &mut idx_at);
    index_lines(&basis_prev, &mut basis_at);
    let mut edited_at: HashMap<u64, i64> = HashMap::new(); // files.edited_mtime, where set
    if !clean && sys::file_exists(&old_db) {
        if let Ok(h) = Db::open_existing(&old_db) {
            if let Ok(st) = h.prepare(b"SELECT file, edited_mtime FROM files WHERE edited_mtime IS NOT NULL") {
                while st.step() == Ok(true) {
                    edited_at.insert(hash(&st.col_text(0)), st.col_int(1));
                }
            }
        }
    }
    // The text the map's rows for a file match while no rows are rewritten
    // from indexer output: "" when that is its current text, "?" unknown.
    let rows_basis = |rel: &[u8], key: u64, full: &[u8], idx_raw: &[u8]| -> Vec<u8> {
        let Some(&t) = edited_at.get(&key) else {
            return idx_raw.to_vec();
        };
        let b = line_of_path(&basis_prev, &basis_at, rel);
        if !b.is_empty() {
            let f = split(b, b'\t');
            if f.len() == 3 && f[2] == t.to_string().as_bytes() {
                return f[1].to_vec();
            }
        }
        if t == sys::mtime_ns(full) {
            return Vec::new();
        }
        b"?".to_vec()
    };
    let mut forced: Vec<u8> = Vec::new(); // paths, one per line
    let mut force_ts = false;
    let mut n_cosmetic = 0;
    prestamp(&walk, repo, out, &texts_dir, &stamps.prev, &stamps.prev_at, &mut stamps.pre, report);
    index_lines(&stamps.pre, &mut stamps.pre_at);
    walk.each_file(repo, |full, name| {
        if cosmetic_lang(name).is_empty() {
            return;
        }
        let st = stamps.stamp(full);
        let rel = &full[repo.len() + 1..];
        let key = hash(rel);
        if !stamps.code_memo.contains(&key) {
            return;
        }
        let raw = stamps.raw_text_of(key);
        let line = line_of_path(&idx_prev, &idx_at, rel);
        if line.is_empty() {
            return; // new since the last map: indexed anyway
        }
        let f = split(line, b'\t');
        if f.len() != 3 {
            return;
        }
        let mut why = f[1] == b"?";
        if !why && f[2] == (st as i64).to_string().as_bytes() {
            // its code is as indexed: no indexer would run for it
            if f[1] != raw && !stamps.have_text(f[1]) {
                why = true;
            }
            let b = rows_basis(rel, key, full, f[1]);
            if !b.is_empty() && b != raw && !stamps.have_text(&b) {
                why = true;
            }
            if !why && f[1] != raw {
                n_cosmetic += 1;
            }
        }
        if why {
            forced.extend_from_slice(rel);
            forced.push(b'\n');
            if cosmetic_lang(name) != b"python" {
                force_ts = true;
            }
        }
    });
    if n_cosmetic > 0 {
        report.extend_from_slice(b"cosmetic edits: ");
        push_int(report, n_cosmetic);
        report.extend_from_slice(b" file(s) changed only in comments or layout; no indexer runs for them\n");
    }
    if !forced.is_empty() {
        report.extend_from_slice(b"reindexing ");
        push_int(report, forced.iter().filter(|&&c| c == b'\n').count() as i64);
        report.extend_from_slice(b" file(s) whose indexed text is unknown\n");
    }
    let _ = force_ts; // read by TypeScript's jobs, still to be carried

    // Carried this far (docs/rust-port.md, "Next"): what was said so far is
    // printed, and the jobs, the indexers and the rows they give are not run.
    print(report);
    crate::not_carried(b"map", 4);
}
